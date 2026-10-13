import AppKit
import GhosttyKit

/// macOS's port of the project file defined in `src/Project.zig` -- the same
/// relationship `macos/Sources/Features/Splits/SplitTree.swift` has to the
/// core's split-tree shape, and `windows/projectfile` has on the Windows
/// side. **Read `Project.zig`'s module comment before changing anything
/// here**: the format, its two versions, what a read puts right, and the
/// rules for writing a string and a number are written down there, once.
/// This file only restates the parts that shape the Swift types.
///
/// What holds the three implementations together is `test/project-format/`:
/// the files there are made by `src/Project.zig`'s tests, and
/// `SharedProjectFilesTests` reads every one and has to write the same bytes
/// back. Nothing here makes those files.
///
/// Deliberately **not** built on `SplitTree<Ghostty.SurfaceView>`'s own
/// `Codable` conformance (the one `TerminalRestorableState` uses for window
/// restoration): that conformance's leaf shape (`pwd`/`uuid`/`title`/
/// `isUserSetTitle`) is a macOS-only restoration format, not this
/// cross-platform one, and its `init(from:)` spins up a live terminal
/// process per leaf as a side effect of decoding -- exactly wrong for
/// something a picker lists without opening. `ProjectFile`/`ProjectNode`
/// are the inert, side-effect-free data; `capture`/`materialize` below are
/// the two, explicit, one-directional bridges to and from live surfaces.
///
/// What the app does with a file once it is read -- which tab is which
/// page, what a save makes of the tabs that are open and the pages that are
/// not -- is `ProjectPages`, and the part that holds real tabs is
/// `ProjectSession`.
///
/// **No memberwise default anywhere in this file's types**, and `encoded()`
/// is the only way to bytes: `ProjectFile` is not `Encodable`, so nothing
/// can hand it to a `JSONEncoder`, whose bytes are not the format's.
struct ProjectFile: Equatable {
    /// The format this build writes, and the latest it reads.
    static let formatVersion = 2

    let name: String

    /// Unix seconds, a whole number: `Project.zig`'s reader requires a JSON
    /// *integer*, so this is never a `Date` or a `Double`.
    let savedAt: Int

    /// The group this project is the project of, or nil for a project with
    /// no group. A project has at most one.
    let group: String?

    /// The windows, in an order that stays the same from one save to the
    /// next (`ProjectPages.updated`) -- not the order they are stacked in on
    /// screen. Empty for a project
    /// with nothing in it.
    let windows: [ProjectWindow]

    /// The next scrollback snapshot number this project will hand out --
    /// see `ProjectScrollback.Allocator`. **One counter for the whole
    /// project**, whatever window or tab a pane is in: every snapshot of a
    /// project is in one directory. Only ever grows, so a number that
    /// belonged to a pane that has since closed is never given to a new one
    /// (which would restore the old pane's history into the new pane).
    /// Absent in files written before snapshots existed.
    let nextScrollback: Int?

    init(name: String, savedAt: Int, group: String?, windows: [ProjectWindow], nextScrollback: Int?) {
        self.name = name
        self.savedAt = savedAt
        self.group = group
        self.windows = windows
        self.nextScrollback = nextScrollback
    }

    /// A project of one window with one tab and no group, the window's
    /// frame not recorded -- what every project was before format 2. A nil
    /// `root` is a project with nothing in it.
    static func oneTab(name: String, savedAt: Int, root: ProjectNode?, nextScrollback: Int?) -> ProjectFile {
        ProjectFile(
            name: name,
            savedAt: savedAt,
            group: nil,
            windows: root.map { [ProjectWindow(frame: nil, front: 0, tabs: [ProjectTab(root: $0)])] } ?? [],
            nextScrollback: nextScrollback)
    }

    /// The tree of the first window's first tab, or nil for a project with
    /// nothing in it. **Nothing that saves or opens a project uses this**:
    /// it is for the settings window's thumbnail, which still draws one
    /// page, and for tests that build a project of one page.
    var firstTab: ProjectNode? {
        windows.first?.tabs.first?.root
    }

    /// Every tab's tree: windows in order, and each window's tabs in order.
    var tabs: [ProjectNode] {
        windows.flatMap { $0.tabs.map(\.root) }
    }

    /// The same project under another name and time: its windows, its group
    /// and its counter go with it.
    func with(name: String, savedAt: Int) -> ProjectFile {
        ProjectFile(name: name, savedAt: savedAt, group: group, windows: windows, nextScrollback: nextScrollback)
    }

    /// Every snapshot filename the project refers to, in any window or tab
    /// -- what a save must count as taken and must not prune.
    var scrollbackFilenames: [String] {
        tabs.flatMap(\.scrollbackFilenames)
    }

    /// Convenience for UI code that wants a `Date` to format.
    var savedAtDate: Date {
        Date(timeIntervalSince1970: TimeInterval(savedAt))
    }

    /// How many panes the first window's first tab has, without
    /// materializing any of them -- the page the settings window draws.
    var paneCount: Int {
        firstTab?.leafCount ?? 0
    }
}

/// One window: its tabs in the order they stood, and which was in front.
struct ProjectWindow: Equatable {
    /// Nil when nothing recorded it, which is every window out of a format
    /// 1 file.
    let frame: ProjectFrame?
    /// The index, in `tabs`, of the tab that was showing.
    let front: Int
    /// Never empty in anything `ProjectFile.decode` returns.
    let tabs: [ProjectTab]
}

/// One tab: a tree of panes.
struct ProjectTab: Equatable {
    let root: ProjectNode
}

/// Where a window was and how big, **as its host had it and nothing more**:
/// in that host's own units, from the corner `origin` names. The screen it
/// was on may be gone when the project is opened again; bringing the window
/// back onto one that is there belongs to whoever opens it.
struct ProjectFrame: Equatable {
    /// Which corner of the screen the frame is measured from. AppKit
    /// measures up from the bottom left and Win32 down from the top left,
    /// and the same four numbers are two different places.
    enum Origin: String {
        case topLeft = "top_left"
        case bottomLeft = "bottom_left"
    }

    let origin: Origin
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

/// Who was working in a pane when the project was saved.
///
/// **Nobody and not known are two answers, and neither is a default.** A
/// pane a person ran a shell in is `.none`; a pane out of a format 1 file,
/// or one nothing could tell about, is `.unknown`.
enum ProjectAgent: Equatable {
    /// Nothing recorded who, if anybody, was here.
    case unknown
    /// Nobody: a pane with no agent in it.
    case none
    /// `role`, `cli` and `session` are the words a group's own file keeps
    /// for its last supervisor under the same names (`LastSupervisor` in
    /// `src/poltergeist/Chat.zig`): each is empty when the agent had none or
    /// nobody could tell which. At most one pane of a project has
    /// `supervisor` set; `ProjectFile.decode` never hands back two.
    case agent(role: String, cli: String, session: String, supervisor: Bool)

    var isSupervisor: Bool {
        if case .agent(_, _, _, true) = self { return true }
        return false
    }
}

/// One node of a project's layout tree. Mirrors `Project.Node` in
/// `src/Project.zig` field for field.
indirect enum ProjectNode: Equatable {
    /// `scrollback` is a snapshot filename inside the project's
    /// `ProjectScrollback.directory`, or empty for a pane saved without one.
    /// Only ever a name `ProjectScrollback.filename(number:)` produces --
    /// the reader drops anything else.
    ///
    /// `bySupervisor` is whether the project's supervisor opened the pane.
    /// It is the pane's and not the agent's: the agent leaves, the pane is
    /// nobody's, and it is still one the supervisor may use again. False
    /// is also what a pane nothing recorded this for reads as.
    case leaf(cwd: String, title: String, history: String, scrollback: String, bySupervisor: Bool, agent: ProjectAgent)
    /// Several terminals in one pane: one showing, the others behind it,
    /// a row of tabs over the pane to choose between them
    /// (`Project.Stack` in `src/Project.zig`).
    ///
    /// **`members` are `.leaf` nodes and nothing else, and there are at
    /// least two**: a stack takes the place of a pane, and one terminal in
    /// a pane is a `.leaf`. `shown` is the index of the one in front; the
    /// order is the order of the tabs. `ProjectFile.decode` never hands
    /// back a stack that is not this, and `encoded()` throws rather than
    /// write one (`ProjectFileError.badStack`) -- build one with `stacked`,
    /// which knows that one member is a leaf.
    case stack(shown: Int, members: [ProjectNode])
    case split(direction: Direction, ratio: Double, left: ProjectNode, right: ProjectNode)

    /// The node for a pane that holds `members`, the one at `shown` in
    /// front: that member itself when it is the only one, a stack of them
    /// when there are more, nil when there are none. `shown` past the end
    /// is the last.
    static func stacked(shown: Int, members: [ProjectNode]) -> ProjectNode? {
        guard let only = members.first else { return nil }
        guard members.count > 1 else { return only }
        return .stack(shown: min(max(shown, 0), members.count - 1), members: members)
    }

    /// Mirrors `Project.Direction` in `src/Project.zig`, which mirrors
    /// `SplitTree.Direction` in `SplitTree.swift`: `horizontal` means the
    /// children sit side by side (the divider between them is a vertical
    /// line). This is a naming trap inherited on purpose -- W1 aligned the
    /// core's naming with what Swift already had, so this does not get to
    /// "fix" it a second time.
    enum Direction: String, Codable {
        case horizontal
        case vertical
    }

    var leafCount: Int {
        switch self {
        case .leaf: return 1
        // Every terminal of a stack is one the person has.
        case .stack(_, let members): return members.reduce(0) { $0 + $1.leafCount }
        case .split(_, _, let left, let right): return left.leafCount + right.leafCount
        }
    }

    var scrollbackFilenames: [String] {
        switch self {
        case .leaf(_, _, _, let scrollback, _, _): return scrollback.isEmpty ? [] : [scrollback]
        case .stack(_, let members): return members.flatMap(\.scrollbackFilenames)
        case .split(_, _, let left, let right): return left.scrollbackFilenames + right.scrollbackFilenames
        }
    }
}

// MARK: - Errors

enum ProjectFileError: LocalizedError, Equatable, CustomStringConvertible {
    /// The file says it is of format `found`, later than
    /// `ProjectFile.formatVersion`: a newer build wrote it. **Not a damaged
    /// file, and never read as format 1** -- the file is whole, and what
    /// this build would make of it is a project with panes missing that the
    /// next save would put on disk.
    case tooNew(found: Int)
    /// A ratio or a frame holds a value that is not a finite number, which
    /// the file has no way to say.
    case notFinite
    /// A stack with fewer than two members, with a member that is not a
    /// pane, or whose `shown` is none of them. Refused rather than written
    /// as something else.
    case badStack

    var description: String {
        switch self {
        case .tooNew(let found):
            return "the project file is format \(found), and this build reads up to format \(ProjectFile.formatVersion): a later version of Polter wrote it"
        case .notFinite:
            return "a split's ratio or a window's frame is not a finite number"
        case .badStack:
            return "a stack has fewer than two members, a member that is not a pane, or shows one it does not have"
        }
    }

    /// So that a log line built from `localizedDescription` -- which is how
    /// a file left out of a listing is reported -- says the above rather
    /// than "The operation couldn't be completed". Not translated: nothing
    /// puts it in front of a person yet, and whatever does should.
    var errorDescription: String? { description }
}

// MARK: - Writing

extension ProjectFile {
    /// The bytes of this project as a format 2 file -- `emit` in
    /// `Project.zig`. **Written by hand rather than through `JSONEncoder`**:
    /// the three implementations have to write the same bytes, and
    /// `JSONEncoder` orders keys its own way, escapes `/`, and prints a
    /// double as Foundation pleases.
    func encoded() throws -> Data {
        var out = "{\"format\":\(Self.formatVersion),\"name\":"
        ProjectFileWriting.string(name, into: &out)
        out += ",\"saved_at\":\(savedAt)"
        out += ",\"root\":{\"kind\":\"moved-to-windows\"}"
        if let group, !group.isEmpty {
            out += ",\"group\":"
            ProjectFileWriting.string(group, into: &out)
        }
        if let nextScrollback { out += ",\"next_scrollback\":\(nextScrollback)" }
        out += ",\"windows\":["
        for (i, window) in windows.enumerated() {
            if i > 0 { out += "," }
            out += "{"
            if let frame = window.frame {
                out += "\"frame\":{\"origin\":\"\(frame.origin.rawValue)\""
                out += ",\"x\":" + (try ProjectFileWriting.number(frame.x))
                out += ",\"y\":" + (try ProjectFileWriting.number(frame.y))
                out += ",\"width\":" + (try ProjectFileWriting.number(frame.width))
                out += ",\"height\":" + (try ProjectFileWriting.number(frame.height))
                out += "},"
            }
            out += "\"front\":\(window.front),\"tabs\":["
            for (j, tab) in window.tabs.enumerated() {
                if j > 0 { out += "," }
                out += "{\"root\":"
                try ProjectFileWriting.node(tab.root, into: &out)
                out += "}"
            }
            out += "]}"
        }
        out += "]}"
        return Data(out.utf8)
    }
}

/// The rules of `Project.zig`'s module comment for writing a node, a string
/// and a number.
enum ProjectFileWriting {
    static func node(_ node: ProjectNode, into out: inout String) throws {
        switch node {
        case .leaf(let cwd, let title, let history, let scrollback, let bySupervisor, let agent):
            out += "{\"kind\":\"leaf\""
            field("cwd", cwd, into: &out)
            field("title", title, into: &out)
            field("history", history, into: &out)
            field("scrollback", scrollback, into: &out)
            if bySupervisor { out += ",\"by_supervisor\":true" }
            out += ",\"agent\":{\"kind\":"
            switch agent {
            case .unknown: out += "\"unknown\""
            case .none: out += "\"none\""
            case .agent(let role, let cli, let session, let supervisor):
                out += "\"agent\""
                field("role", role, into: &out)
                field("cli", cli, into: &out)
                field("session", session, into: &out)
                out += supervisor ? ",\"supervisor\":true" : ",\"supervisor\":false"
            }
            out += "}}"

        case .stack(let shown, let members):
            guard members.count >= 2, members.indices.contains(shown),
                  members.allSatisfy({ if case .leaf = $0 { return true } else { return false } })
            else { throw ProjectFileError.badStack }
            out += "{\"kind\":\"stack\",\"shown\":\(shown),\"members\":["
            for (i, member) in members.enumerated() {
                if i > 0 { out += "," }
                try self.node(member, into: &out)
            }
            out += "]}"

        case .split(let direction, let ratio, let left, let right):
            out += "{\"kind\":\"split\",\"direction\":\"\(direction.rawValue)\",\"ratio\":"
            out += try number(ratio)
            out += ",\"left\":"
            try self.node(left, into: &out)
            out += ",\"right\":"
            try self.node(right, into: &out)
            out += "}"
        }
    }

    /// `,"key":"value"`, or nothing when the value is empty.
    static func field(_ key: String, _ value: String, into out: inout String) {
        guard !value.isEmpty else { return }
        out += ",\"\(key)\":"
        string(value, into: &out)
    }

    /// The scalars between quotes, with `"` and `\` behind a backslash and
    /// everything below U+0020 as `\u00xx`. Nothing else is escaped.
    static func string(_ value: String, into out: inout String) {
        out += "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case _ where scalar.value < 0x20:
                let hex = String(scalar.value, radix: 16)
                out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
            default: out.unicodeScalars.append(scalar)
            }
        }
        out += "\""
    }

    /// The shortest decimal that reads back as `value`, written out in full:
    /// never an exponent, and no point on a whole value.
    ///
    /// `"\(value)"` already has the right digits -- it is the shortest text
    /// that reads back as the same double -- but not the right form: `1.0`
    /// for a whole value, `1e-07` for a small one. So the digits are taken
    /// from it and laid out again.
    static func number(_ value: Double) throws -> String {
        guard value.isFinite else { throw ProjectFileError.notFinite }
        var text = Substring("\(value)")
        let negative = text.hasPrefix("-")
        if negative { text = text.dropFirst() }

        var exponent = 0
        if let e = text.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            exponent = Int(text[text.index(after: e)...]) ?? 0
            text = text[..<e]
        }
        let parts = text.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let whole = String(parts[0])
        let fraction = parts.count > 1 ? String(parts[1]) : ""
        let digits = whole + fraction
        // Where the point goes among `digits`, counted from their left.
        let point = whole.count + exponent

        var integer: String
        var decimals: String
        if point <= 0 {
            integer = "0"
            decimals = String(repeating: "0", count: -point) + digits
        } else if point >= digits.count {
            integer = digits + String(repeating: "0", count: point - digits.count)
            decimals = ""
        } else {
            integer = String(digits.prefix(point))
            decimals = String(digits.dropFirst(point))
        }
        while integer.count > 1, integer.hasPrefix("0") { integer.removeFirst() }
        while decimals.hasSuffix("0") { decimals.removeLast() }
        return (negative ? "-" : "") + integer + (decimals.isEmpty ? "" : "." + decimals)
    }
}

// MARK: - Reading

extension ProjectFile {
    /// The format `data` says it is: 1 for a file with no `format` key.
    /// Throws `ProjectFileError.tooNew` for a later one than this build
    /// reads, and a decoding error for anything that is not a version.
    static func format(of data: Data) throws -> Int {
        let found = try JSONDecoder().decode(ProjectFileReading.Format.self, from: data).value
        guard found >= 1 else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "project format \(found) is not a format"))
        }
        guard found <= formatVersion else { throw ProjectFileError.tooNew(found: found) }
        return found
    }

    /// Read a project file of either format. Never half a project: a
    /// format 2 file missing anything format 2 always writes is an error,
    /// as is a split missing a child in either.
    static func decode(from data: Data) throws -> Self {
        // The format first, before anything is made of the rest: a file
        // from a later build is refused whole, not read for the keys this
        // build happens to share with it.
        let found = try format(of: data)
        let decoder = JSONDecoder()
        decoder.userInfo[ProjectFileReading.formatKey] = found
        return try decoder.decode(ProjectFileReading.File.self, from: data).file.puttingRight()
    }

    /// What `Project.zig`'s module comment says a read puts right: a
    /// snapshot name an earlier pane already has reads as none, and **when
    /// two or more panes say they are the supervisor, none of them is**.
    func puttingRight() -> ProjectFile {
        var seen: Set<String> = []
        let supervisors = tabs.reduce(0) { $0 + $1.supervisorCount }
        return ProjectFile(
            name: name,
            savedAt: savedAt,
            group: group,
            windows: windows.map { window in
                ProjectWindow(frame: window.frame, front: window.front, tabs: window.tabs.map {
                    ProjectTab(root: $0.root.puttingRight(seen: &seen, demoting: supervisors > 1))
                })
            },
            nextScrollback: nextScrollback)
    }
}

extension ProjectNode {
    var supervisorCount: Int {
        switch self {
        case .leaf(_, _, _, _, _, let agent): return agent.isSupervisor ? 1 : 0
        case .stack(_, let members): return members.reduce(0) { $0 + $1.supervisorCount }
        case .split(_, _, let left, let right): return left.supervisorCount + right.supervisorCount
        }
    }

    /// Left before right, and a stack's members in their order, which is
    /// the order `seen` is filled in.
    fileprivate func puttingRight(seen: inout Set<String>, demoting: Bool) -> ProjectNode {
        switch self {
        case .leaf(let cwd, let title, let history, let scrollback, let bySupervisor, var agent):
            let kept = scrollback.isEmpty || seen.insert(scrollback).inserted
            if demoting, case .agent(let role, let cli, let session, _) = agent {
                agent = .agent(role: role, cli: cli, session: session, supervisor: false)
            }
            return .leaf(
                cwd: cwd, title: title, history: history, scrollback: kept ? scrollback : "",
                bySupervisor: bySupervisor, agent: agent)

        case .stack(let shown, let members):
            var put: [ProjectNode] = []
            for member in members {
                put.append(member.puttingRight(seen: &seen, demoting: demoting))
            }
            return .stack(shown: shown, members: put)

        case .split(let direction, let ratio, let left, let right):
            let first = left.puttingRight(seen: &seen, demoting: demoting)
            return .split(direction: direction, ratio: ratio, left: first, right: right.puttingRight(seen: &seen, demoting: demoting))
        }
    }
}

/// The decoding of a project file. Private to reading on purpose: the types
/// here decode by the format `ProjectFile.decode` found first, and a
/// `ProjectNode` decoded without being told which would have to guess.
enum ProjectFileReading {
    static let formatKey = CodingUserInfoKey(rawValue: "polter.project-file-format")!

    private static func format(_ decoder: Decoder) throws -> Int {
        guard let format = decoder.userInfo[formatKey] as? Int else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "a project file is read with ProjectFile.decode(from:), which says which format it is"))
        }
        return format
    }

    /// A key that, when it is there, has to be a string: JSON `null` and
    /// anything else is an error, and absent is empty.
    private static func strictString<K: CodingKey>(_ container: KeyedDecodingContainer<K>, _ key: K) throws -> String {
        container.contains(key) ? try container.decode(String.self, forKey: key) : ""
    }

    struct Format: Decodable {
        let value: Int

        private enum CodingKeys: String, CodingKey { case format }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // Present is a number, `null` included: only a file with no
            // such key is format 1.
            value = container.contains(.format) ? try container.decode(Int.self, forKey: .format) : 1
        }
    }

    struct File: Decodable {
        let file: ProjectFile

        private enum CodingKeys: String, CodingKey {
            case name
            case savedAt = "saved_at"
            case root
            case group
            case windows
            case nextScrollback = "next_scrollback"
        }

        init(from decoder: Decoder) throws {
            let format = try ProjectFileReading.format(decoder)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let name = try container.decode(String.self, forKey: .name)
            let savedAt = try container.decode(Int.self, forKey: .savedAt)
            let nextScrollback = try container.decodeIfPresent(Int.self, forKey: .nextScrollback)

            guard format >= 2 else {
                // One tab is one window with that tab in it; no `root` is a
                // project with nothing in it.
                let root = try container.decodeIfPresent(Node.self, forKey: .root)?.node
                file = .oneTab(name: name, savedAt: savedAt, root: root, nextScrollback: nextScrollback)
                return
            }

            let group = try ProjectFileReading.strictString(container, .group)
            file = ProjectFile(
                name: name,
                savedAt: savedAt,
                group: group.isEmpty ? nil : group,
                windows: try container.decode([Window].self, forKey: .windows).map(\.window),
                nextScrollback: nextScrollback)
        }
    }

    struct Window: Decodable {
        let window: ProjectWindow

        private enum CodingKeys: String, CodingKey { case frame, front, tabs }
        private enum TabKeys: String, CodingKey { case root }
        private enum FrameKeys: String, CodingKey { case origin, x, y, width, height }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)

            var frame: ProjectFrame?
            if container.contains(.frame) {
                let f = try container.nestedContainer(keyedBy: FrameKeys.self, forKey: .frame)
                guard let origin = ProjectFrame.Origin(rawValue: try f.decode(String.self, forKey: .origin)) else {
                    throw DecodingError.dataCorruptedError(forKey: .origin, in: f, debugDescription: "unknown frame origin")
                }
                frame = ProjectFrame(
                    origin: origin,
                    x: try f.decode(Double.self, forKey: .x),
                    y: try f.decode(Double.self, forKey: .y),
                    width: try f.decode(Double.self, forKey: .width),
                    height: try f.decode(Double.self, forKey: .height))
            }

            var list = try container.nestedUnkeyedContainer(forKey: .tabs)
            var tabs: [ProjectTab] = []
            while !list.isAtEnd {
                let tab = try list.nestedContainer(keyedBy: TabKeys.self)
                tabs.append(ProjectTab(root: try tab.decode(Node.self, forKey: .root).node))
            }
            let front = try container.decode(Int.self, forKey: .front)
            guard !tabs.isEmpty, front >= 0, front < tabs.count else {
                throw DecodingError.dataCorruptedError(
                    forKey: .front, in: container,
                    debugDescription: "a window has \(tabs.count) tab(s) and says tab \(front) is in front")
            }
            window = ProjectWindow(frame: frame, front: front, tabs: tabs)
        }
    }

    struct Node: Decodable {
        let node: ProjectNode

        private enum CodingKeys: String, CodingKey {
            case kind, cwd, title, history, scrollback, agent, direction, ratio, left, right
            case shown, members
            case bySupervisor = "by_supervisor"
        }

        private enum AgentKeys: String, CodingKey { case kind, role, cli, session, supervisor }

        init(from decoder: Decoder) throws {
            let format = try ProjectFileReading.format(decoder)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let kind = try container.decode(String.self, forKey: .kind)
            switch kind {
            case "leaf":
                // A `scrollback` that isn't a plain `<n>.snap` is read as absent,
                // not as an error: the core deletes a snapshot it can't decode, so
                // resolving an arbitrary path from a project file would let the
                // file delete things; and failing the whole decode would make one
                // bad field cost the user the entire project.
                let scrollback = try container.decodeIfPresent(String.self, forKey: .scrollback) ?? ""
                node = .leaf(
                    cwd: try container.decodeIfPresent(String.self, forKey: .cwd) ?? "",
                    title: try container.decodeIfPresent(String.self, forKey: .title) ?? "",
                    history: try container.decodeIfPresent(String.self, forKey: .history) ?? "",
                    scrollback: ProjectScrollback.isSnapshotFilename(scrollback) ? scrollback : "",
                    // New with format 2 and strict as the agent is: absent
                    // is false, anything but a boolean (`null` included)
                    // is an error.
                    bySupervisor: format >= 2 && container.contains(.bySupervisor)
                        ? try container.decode(Bool.self, forKey: .bySupervisor) : false,
                    // A format 1 file never said, whatever keys it has.
                    agent: format >= 2 ? try Self.agent(container) : .unknown)

            case "stack":
                // Format 1 has no such node. And nothing about a stack is
                // put right (`Project.zig`'s module comment says why):
                // fewer than two members, a member that is not a pane, or
                // a `shown` that is none of them is an error.
                guard format >= 2 else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .kind, in: container, debugDescription: "a format 1 project file has no stacks")
                }
                let members = try container.decode([Node].self, forKey: .members).map(\.node)
                let shown = try container.decode(Int.self, forKey: .shown)
                guard members.count >= 2, members.indices.contains(shown),
                      members.allSatisfy({ if case .leaf = $0 { return true } else { return false } })
                else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .members, in: container,
                        debugDescription: "a stack has \(members.count) member(s), not all of them panes, or shows number \(shown)")
                }
                node = .stack(shown: shown, members: members)

            case "split":
                // Both children are required. A split with only a `left` is
                // exactly the "half a tree" this format's reader (on every
                // platform) promises never to hand back, so a missing child
                // fails the whole decode -- the same as `Project.zig`'s
                // `parseNode`, which requires both before returning a node at
                // all rather than producing a lopsided one.
                node = .split(
                    direction: try container.decode(ProjectNode.Direction.self, forKey: .direction),
                    ratio: try container.decode(Double.self, forKey: .ratio),
                    left: try container.decode(Node.self, forKey: .left).node,
                    right: try container.decode(Node.self, forKey: .right).node)

            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .kind,
                    in: container,
                    debugDescription: "unknown project node kind '\(kind)'")
            }
        }

        /// Strict where the rest of a leaf is not: these keys are new with
        /// format 2, so nothing older wrote them any other way.
        private static func agent(_ leaf: KeyedDecodingContainer<CodingKeys>) throws -> ProjectAgent {
            let container = try leaf.nestedContainer(keyedBy: AgentKeys.self, forKey: .agent)
            let kind = try container.decode(String.self, forKey: .kind)
            switch kind {
            case "unknown": return .unknown
            case "none": return .none
            case "agent":
                return .agent(
                    role: try ProjectFileReading.strictString(container, .role),
                    cli: try ProjectFileReading.strictString(container, .cli),
                    session: try ProjectFileReading.strictString(container, .session),
                    supervisor: try container.decode(Bool.self, forKey: .supervisor))
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .kind, in: container, debugDescription: "unknown agent kind '\(kind)'")
            }
        }
    }
}

// MARK: - Listing

enum ProjectListing {
    /// Decode each of `urls` as a project file, skipping any that can't be
    /// read or decoded.
    ///
    /// Skipping is deliberate and shared with the other ports -- a listing
    /// is an inventory for a picker, not a load, so one bad file shouldn't
    /// empty it (`list` in `src/Project.zig`, `list` in
    /// `windows/host/src/project.rs`). Changing it here alone would make
    /// the platforms disagree about which projects exist. What was wrong
    /// was the skip being silent: a project that disappears from the picker
    /// has to leave a trace somewhere, so every skip is handed to `skipped`
    /// -- a file from a later format with `ProjectFileError.tooNew`.
    static func decode(_ urls: [URL], skipped: (URL, Error) -> Void) -> [(url: URL, file: ProjectFile)] {
        urls.compactMap { url in
            do {
                return (url, try ProjectFile.decode(from: Data(contentsOf: url)))
            } catch {
                skipped(url, error)
                return nil
            }
        }
    }
}

// MARK: - Capture (live surfaces -> data)

extension ProjectNode {
    /// Capture a live split tree's shape and each pane's `cwd`/`title`/
    /// `history` as portable data. Pure: reads the surfaces, doesn't touch
    /// them.
    ///
    /// `history` is whatever the core named this surface's capture file as
    /// (`view.historyFilename`, set once by `GHOSTTY_ACTION_HISTORY_FILENAME`
    /// -- see `Ghostty.App.historyFilename`), or empty when history capture
    /// was never on for this surface. Opaque either way: this apprt doesn't
    /// parse it, just carries it. An empty string round-trips fine per
    /// `Project.zig`'s reader (`history` is optional on every leaf).
    ///
    /// `scrollback` is asked once per leaf and returns the snapshot filename
    /// to record for that pane, or empty for none. It is the one non-pure
    /// part: `ProjectStore.save` passes a closure that looks up (or hands
    /// out) the pane's own snapshot name and may ask the core to write it.
    ///
    /// `who` is asked once per leaf too, and says who is working in that
    /// pane and whether the project's supervisor opened it. **Neither has a
    /// default**: a caller that left `who` out would be writing down an
    /// answer it never gave.
    static func capturing(
        _ node: SplitTree<Ghostty.SurfaceView>.Node,
        scrollback: (Ghostty.SurfaceView) -> String,
        who: (Ghostty.SurfaceView) -> (agent: ProjectAgent, bySupervisor: Bool)
    ) -> ProjectNode {
        switch node {
        case .leaf(let view):
            return .leaf(
                cwd: view.pwd ?? "",
                title: view.title,
                history: view.historyFilename ?? "",
                scrollback: scrollback(view),
                bySupervisor: who(view).bySupervisor,
                agent: who(view).agent)

        case .split(let split):
            return .split(
                direction: Direction(split.direction),
                ratio: split.ratio,
                left: capturing(split.left, scrollback: scrollback, who: who),
                right: capturing(split.right, scrollback: scrollback, who: who))
        }
    }
}

private extension ProjectNode.Direction {
    init(_ direction: SplitTree<Ghostty.SurfaceView>.Direction) {
        switch direction {
        case .horizontal: self = .horizontal
        case .vertical: self = .vertical
        }
    }

    var splitTreeDirection: SplitTree<Ghostty.SurfaceView>.Direction {
        switch self {
        case .horizontal: return .horizontal
        case .vertical: return .vertical
        }
    }
}

// MARK: - Materialize (data -> live surfaces)

extension ProjectNode {
    /// Rebuild live surfaces from this node -- each leaf spins up a real
    /// terminal process at its saved `cwd` (or the shell's default when
    /// `cwd` no longer exists; `Exec.zig` already falls back rather than
    /// failing, see `if (std.Io.Dir.cwd().access(...))` in
    /// `src/termio/Exec.zig`). The result is ready to hand to
    /// `TerminalController(withSurfaceTree:)`.
    ///
    /// `scrollback` is where this project's snapshots live (see
    /// `ProjectScrollback.directory`) and the project they belong to; nil
    /// restores no scrollback at all.
    func materializing(
        _ app: ghostty_app_t,
        scrollback project: ProjectScrollback.Location? = nil
    ) -> SplitTree<Ghostty.SurfaceView>.Node {
        switch self {
        // ⚠️ **Only the member in front is brought back, for now.** Putting
        // a stack back as one pane with every member in it, the one at
        // `shown` in front, is the work of whoever wires the split tree's
        // stacks to this (#1493); until then a project with a stack opens
        // with that pane's front terminal only, and the first save after
        // would write it without the others.
        case .stack(let shown, let members):
            return members[min(max(shown, 0), members.count - 1)].materializing(app, scrollback: project)

        // Who was in the pane is not acted on here: a restored pane is a
        // terminal in the right place, and starting an agent in it is a
        // decision for whoever opens the project.
        case .leaf(let cwd, let title, let history, let scrollback, _, _):
            var config = Ghostty.SurfaceConfiguration()
            if !cwd.isEmpty { config.workingDirectory = cwd }
            // Passed through opaquely -- see `SurfaceConfiguration.historyRestore`.
            // The core decides what it means per shell once it knows which
            // shell this pane is running (`Exec.zig`, after shell detection).
            if !history.isEmpty { config.historyRestore = history }
            // No existence check here, deliberately: a missing, stale or
            // corrupt snapshot is the core's to handle (it starts an empty
            // terminal and deletes the file), and checking here would only
            // add a second, racier opinion about the same file.
            if let project, !scrollback.isEmpty {
                config.scrollbackRestore = project.directory.appendingPathComponent(scrollback).path
            }
            let view = Ghostty.SurfaceView(app, baseConfig: config)
            // Not forced into the "explicitly named" tier (see
            // `titleFromTerminal` in `SurfaceView_AppKit.swift`): a saved
            // title is a snapshot of what the pane showed, not necessarily
            // something a person chose, so it's free to be replaced once
            // the shell reports its own title.
            if !title.isEmpty { view.setTitle(title) }
            // The pane keeps the snapshot name it was saved under, so its
            // next save writes the same file wherever the pane has moved to --
            // and from now on the core keeps that file up to date. This is
            // the restored pane's journal: it has none yet, so this starts
            // one, and its first write rewrites the file from what was just
            // restored.
            if let project, !scrollback.isEmpty {
                view.journalScrollback(.init(project: project.key, filename: scrollback), in: project.directory)
            }
            return .leaf(view: view)

        case .split(let direction, let ratio, let left, let right):
            return .split(.init(
                direction: direction.splitTreeDirection,
                ratio: ratio,
                left: left.materializing(app, scrollback: project),
                right: right.materializing(app, scrollback: project)))
        }
    }
}
