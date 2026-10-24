import Foundation

/// Which frame a pane of a split wears, and what its title says
/// (`control-room.md`, 12.6; the design's `06-panes`).
///
/// **Which of the three is the core's answer.** It arrives as `pane` on
/// each of the snapshot's `terminals`, with the title, the glyph and the
/// word beside it. Nothing here asks what a terminal's role is. What is
/// decided here is only whether a frame is drawn at all, and that is about
/// where the pane is -- which is the host's to know -- and not about what
/// is in it.
///
/// Nothing in this file touches a view: `PaneFrameView` draws what this
/// says.
enum PaneFrame {
    /// The core's three: supervisor, worker, plain.
    typealias Kind = ControlRoomSnapshot.Terminal.Pane

    /// The name, the glyph and the word. The same three a supervisor's
    /// frame in the control room has always been given.
    struct Title: Equatable {
        var name: String
        /// The glyph at the title's right end: a status, or `held`.
        var shown: ControlRoomSnapshot.Terminal.Bar.Shown
        var word: String
        /// Whose word follows the name, when it is not the frame's own
        /// (`ControlRoomList.SupervisorTitle.says`); nil for a pane of a
        /// split, whose frame is what it is.
        var says: Kind?
        /// What the core says of a supervisor started by hand, before the
        /// status (`SupervisorTitle.note`); nil for every other title.
        var note: String?
        /// "Let the control room take over?" (`SupervisorTitle.takeOver`).
        var takeOver: ControlRoomList.TakeOverTitle?
        /// A supervisor's title says what it is with the badge
        /// (`badge(in:)`): the title of a pane of a split. Not the control
        /// room's own frame, which is the supervisor's and nothing else, and
        /// which the Windows host draws without one too.
        var badged: Bool
        /// The colour the user set on the pane (task 1699); `.none` for
        /// none, and for every title that is not a pane's. The host knows
        /// it, not the snapshot: the split view sets it from the surface.
        var color: PaneColor = .none
        /// "<Agent CLI> custom model" for a terminal started through an
        /// Agent CLI of the person's own (task 2156, `customModel`); nil
        /// for every other.
        var model: String?

        init(name: String, shown: ControlRoomSnapshot.Terminal.Bar.Shown, word: String, says: Kind? = nil, note: String? = nil,
             takeOver: ControlRoomList.TakeOverTitle? = nil, badged: Bool = false, color: PaneColor = .none, model: String? = nil) {
            self.name = name
            self.shown = shown
            self.word = word
            self.says = says
            self.note = note
            self.takeOver = takeOver
            self.badged = badged
            self.color = color
            self.model = model
        }

        /// The control room's own frame: the supervisor's status, which is
        /// one of the row's glyphs, and the word the title brings with it.
        init(_ supervisor: ControlRoomList.SupervisorTitle) {
            self.init(name: supervisor.name, shown: .init(supervisor.shown), word: supervisor.word, says: supervisor.says,
                      note: supervisor.note, takeOver: supervisor.takeOver)
        }

        /// The word after the name on the bar of a frame that is `wears`:
        /// the title's own when it brings one, the frame's otherwise.
        func roleWord(in wears: Kind) -> String? {
            PaneFrame.roleWord(says ?? wears)
        }

        /// Whether the bar of a frame that is `wears` says what it is with
        /// the supervisor's badge, in place of the word after the name
        /// (task 1692, the design's `supervisor-pane-v1` C): on a pane of a
        /// split (`badged`), whenever that word would be the supervisor's.
        func badge(in wears: Kind) -> Bool {
            badgeKind(in: wears) == .flag
        }

        /// What the badge at the left of the bar of a frame that is
        /// `wears` holds (task 1699): the supervisor's flag; for any other
        /// pane given a colour, a dot; or no badge. Only on a pane of a
        /// split (`badged`).
        func badgeKind(in wears: Kind) -> Badge {
            guard badged else { return .none }
            if (says ?? wears) == .supervisor { return .flag }
            return color == .none ? .none : .dot
        }

        /// The colour the pane is shown in: what was set, and a
        /// supervisor's purple when nothing was.
        func shownColor(in wears: Kind) -> PaneColor {
            PaneColor.shown(set: color, supervisor: (says ?? wears) == .supervisor)
        }

        /// The word on the badge: what the pane is -- the supervisor's word,
        /// or a worker's -- and nothing for an ordinary terminal, whose
        /// badge is its dot alone.
        func badgeWord(in wears: Kind) -> String {
            switch badgeKind(in: wears) {
            case .none: return ""
            case .flag: return PaneFrame.roleWord(.supervisor) ?? ""
            case .dot: return PaneFrame.roleWord(says ?? wears) ?? ""
            }
        }
    }

    /// What the badge at the left of a pane's title holds.
    enum Badge: Equatable {
        case none
        /// The supervisor's flag and its word.
        case flag
        /// A dot in the pane's colour, and the word for what it is when it
        /// has one (a worker).
        case dot

        var name: String {
            switch self {
            case .none: return "none"
            case .flag: return "flag"
            case .dot: return "dot"
            }
        }
    }

    /// What one pane wears.
    struct Drawn: Equatable {
        var wears: Kind
        var title: Title
    }

    /// Where a pane is.
    struct Place: Equatable {
        /// `poltergeist-pane-frames`.
        var enabled: Bool
        /// It is in the quick terminal, which is never framed.
        var quickTerminal: Bool
        /// It is the only pane showing in its tab: the tab is not split, or
        /// this pane is zoomed to fill it.
        var alone: Bool
    }

    /// What the pane of `terminal` wears at `place`; nil when it is drawn
    /// as it was before there were frames.
    ///
    /// - A terminal `terminals` (the snapshot's) does not list -- one the
    ///   core has not placed yet, or no snapshot at all -- is an ordinary one, under
    ///   the name its own view has (`ownName`), with nothing to say.
    /// - An ordinary terminal alone in its tab wears nothing: the window's
    ///   tab already says which it is. A supervisor or a worker wears its
    ///   frame even alone.
    static func drawn(terminal: String?, ownName: String, at place: Place,
                      in terminals: [ControlRoomSnapshot.Terminal]?) -> Drawn? {
        guard place.enabled, !place.quickTerminal else { return nil }
        let listed = terminal.flatMap { id in terminals?.first { $0.id == id } }
        let drawn = listed.map { listed in
            // The pair the core says the title draws. Only a snapshot from
            // before it said so falls back to the status.
            let shown = listed.bar?.shown ?? .init(listed.shown)
            let wears = listed.pane ?? .plain
            return Drawn(wears: wears, title: Title(name: listed.title, shown: shown, word: ControlRoomList.say(listed.bar?.text ?? listed.text),
                                                    badged: true, model: customModel(listed.who)))
        }
            ?? Drawn(wears: .plain, title: Title(name: ownName, shown: .none, word: "", badged: true))
        if drawn.wears == .plain, place.alone { return nil }
        return drawn
    }

    /// What a terminal started through an Agent CLI of the person's own
    /// says where its CLI's name would be (task 2156): that Agent CLI's
    /// name, and "custom model" -- it is not spending the CLI account's
    /// allowance. Its key when the core said no name; nil when it was not
    /// started through one.
    static func customModel(_ who: ControlRoomSnapshot.Terminal.Who?) -> String? {
        guard let who, who.is == .agent, let key = who.launcher, !key.isEmpty else { return nil }
        let name = who.launcher_name.flatMap { $0.isEmpty ? nil : $0 } ?? key
        return String(localized: "\(name) custom model",
                      comment: "分屏框与层叠标签：走用户自己的 Agent CLI 起的终端，写在 CLI 名的位置；%@ 是那个 Agent CLI 的名字")
    }

    /// The ground of a badge, for the colour the pane is shown in: the
    /// supervisor's purple (the app icon's) when it is none. **The one
    /// place it is chosen** (task 1692; the colours, task 1699).
    static func badgeGround(_ shown: PaneColor, theme: ControlRoomLook.Theme) -> ControlRoomLook.RGBA {
        shown.badge(theme) ?? theme.panePurpleBadge
    }

    /// The word and the mark on that badge.
    static func badgeText(_ shown: PaneColor, theme: ControlRoomLook.Theme) -> ControlRoomLook.RGBA {
        shown.badgeText(theme) ?? theme.panePurpleBadgeText
    }

    /// Whether the pane of `terminal` at `place` is drawn with the
    /// supervisor's edge: a line just inside it, all round, and nothing
    /// else (task 1692, the design's `supervisor-pane-v1`, situation 2).
    /// Only where it wears no frame because the setting is off -- with no
    /// title there is nowhere for the badge to go -- and for the core's
    /// supervisor only; alone in its tab too, as its frame would be. Never
    /// in the quick terminal, which is never framed.
    static func edged(terminal: String?, at place: Place, in terminals: [ControlRoomSnapshot.Terminal]?) -> Bool {
        edge(terminal: terminal, at: place, in: terminals, color: .none) != nil
    }

    /// The colour of that line (task 1699): the colour the pane is shown
    /// in, for a supervisor and for any pane given a colour -- with no
    /// title, the line is where the colour goes. Nil for no line.
    static func edge(terminal: String?, at place: Place, in terminals: [ControlRoomSnapshot.Terminal]?,
                     color: PaneColor) -> PaneColor? {
        guard !place.enabled, !place.quickTerminal else { return nil }
        let listed = terminal.flatMap { id in terminals?.first { $0.id == id } }
        let shown = PaneColor.shown(set: color, supervisor: listed?.pane == .supervisor)
        return shown == .none ? nil : shown
    }

    /// Whether the tab's ground shows between and around its panes: it
    /// does as soon as one pane of it wears a frame. With none framed the
    /// panes meet at the divider, as they always did.
    static func groundShows(_ panes: [Drawn?]) -> Bool {
        panes.contains { $0 != nil }
    }

    /// The word after the name that says what the pane is; nil for an
    /// ordinary terminal, which says nothing.
    static func roleWord(_ wears: Kind) -> String? {
        switch wears {
        case .supervisor:
            return String(localized: "Supervisor", comment: "总控台：右栏总管框标题条上，名字后面说明身份的字")
        case .worker:
            return String(localized: "Worker", comment: "分屏框：worker 那一格的标题带上，名字后面说明身份的字")
        case .plain:
            return nil
        }
    }
}
