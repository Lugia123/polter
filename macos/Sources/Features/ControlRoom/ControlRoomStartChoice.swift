import Foundation

/// What starting a supervisor says of the one the group last had, and which
/// session the start is asked to use (`control-room.md`, 7.5; v20, rules 11
/// and 12).
///
/// **Whether the last session can be gone on with is the core's word**
/// (`resume.can`), and so is why not (`resume.why`). What is here is only
/// which sentence each of those is, whether the choice is drawn, and what
/// is sent. The Windows host's `scene::last_supervisor_words`,
/// `resume_note` and `act::Session` are the same rules, and
/// `tools/control-room-hosts-agree.py` holds the two to one answer.
enum ControlRoomStartChoice {
    typealias Start = ControlRoomList.SupervisorStart

    /// Which session a start is asked for: the core's two words
    /// (`ControlAct.zig`, `Session`).
    enum Session: String, Equatable, CaseIterable {
        /// Go on with the session the group's last supervisor was in.
        case last
        case new
    }

    /// Whether the two-way choice is drawn: only when the core says a
    /// start can go on with the last session. Offering it otherwise would
    /// be offering something that then does not happen.
    static func offersSession(_ start: Start?) -> Bool {
        start?.last?.canResume == true
    }

    /// What the start sends for `session`; nil to leave it out. With the
    /// choice on screen it is what is selected there -- the last session
    /// until the person picks the other. With no choice on screen nothing
    /// is said: the core starts a new session where the last cannot be
    /// gone on with, and a host that said "new" there would be deciding it
    /// a second time.
    static func sessionSent(offered: Bool, picked: Session?) -> Session? {
        offered ? (picked ?? .last) : nil
    }

    // MARK: Which agent CLI (task 1677)

    /// "Go on with the last session", for the CLI picked: on and pickable
    /// (`live`), drawn greyed because another CLI could and this one cannot
    /// (`greyed`), or not drawn (`hidden`). The Windows host's
    /// `scene::Resume`.
    enum Resume: String, Equatable {
        case live, greyed, hidden
    }

    /// The CLI row and what it does to the session choice.
    struct CliChoice: Equatable {
        /// The CLIs of the role the start is in, in its order.
        var clis: [ControlRoomList.SupervisorRole.Cli]
        /// The "Agent CLI" row is drawn: more than one to choose from.
        var shown: Bool
        /// The CLI the start uses; nil when the core names none.
        var picked: String?
        var resume: Resume
        /// Why the picked CLI does not go on with the last session; `none`
        /// when it does.
        var why: Start.ResumeWhy
        /// The CLI the last supervisor used, by name, when the role holds
        /// it back because its program is not here (task 1744); nil
        /// otherwise. `scene::CliChoice::last_gone`.
        var lastGone: String?
    }

    /// Whether a start in `cli` goes on with the last session, and why not:
    /// the core's answer for that CLI (`resume_by_cli`), never one worked
    /// out here. A core from before it said gives the one answer it has, for
    /// the CLI it names; a CLI it gives no answer for is not gone on with.
    /// The Windows host's `scene::resume_for`.
    static func resume(_ last: Start.Last, for cli: String?) -> (can: Bool, why: Start.ResumeWhy) {
        if let one = last.byCli.first(where: { $0.cli == cli }) { return (one.can, one.why) }
        if last.byCli.isEmpty || cli == last.cli { return (last.canResume, last.why) }
        return (false, .cliDiffers)
    }

    /// The CLI choice for a start in `role` (the core's when nil), with
    /// `picked` the CLI the person pressed, nil while they pressed none.
    ///
    /// Which is on before they press: for the core's role, the core's
    /// (`supervisor.cli`); for another, the CLI the last supervisor used
    /// when the role lists it, else the role's first -- the core's own rule
    /// (`startCliOf`). A pick the role does not list is not kept. The
    /// Windows host's `scene::cli_choice`; `hosts-agree` prints both.
    static func cliChoice(_ start: Start, roles: [ControlRoomList.SupervisorRole],
                          role: String?, picked: String?) -> CliChoice {
        let key = role ?? start.role
        let clis = key.flatMap { k in roles.first { $0.key == k } }?.clis ?? []
        func listed(_ c: String) -> Bool { clis.contains { $0.key == c } }
        let last = start.last
        let coreDefault = key == start.role ? last?.cli : nil
        let chosen = picked.flatMap { listed($0) ? $0 : nil }
            ?? coreDefault.flatMap { clis.isEmpty || listed($0) ? $0 : nil }
            ?? last?.lastCli.flatMap { listed($0) ? $0 : nil }
            ?? clis.first?.key
        let shown = clis.count > 1
        guard let last else {
            return CliChoice(clis: clis, shown: shown, picked: chosen, resume: .hidden, why: .noRecord, lastGone: nil)
        }
        // The last supervisor's CLI, held back because it is not installed here.
        let held = key.flatMap { k in roles.first { $0.key == k } }?.heldBack
            .first { $0.key == last.lastCli }
        let lastGone = held?.why == .notInstalled
            ? cliName(key: last.lastCli, label: held?.label ?? last.lastCliLabel) : nil
        let (can, why) = resume(last, for: chosen)
        let state: Resume
        if can {
            state = .live
        } else if shown && clis.contains(where: { resume(last, for: $0.key).can }) {
            state = .greyed
        } else {
            state = .hidden
        }
        return CliChoice(clis: clis, shown: shown, picked: chosen, resume: state, why: can ? .none : why,
                         lastGone: lastGone)
    }

    /// What the start sends for its session: the one picked while "Go on"
    /// can be picked, and nothing otherwise -- greyed or not drawn, the
    /// core starts a new one by itself. `scene::session_for`.
    static func sessionSent(_ choice: CliChoice, picked: Session?) -> Session? {
        sessionSent(offered: choice.resume == .live, picked: picked)
    }

    /// The sentence under the sessions; nil when there is nothing to say.
    /// Greyed because another CLI was picked: whose session it was, and
    /// which CLI cannot go on with it. Otherwise the core's reason
    /// (`resumeNote`). `scene::resume_said`.
    static func resumeSaid(_ choice: CliChoice, last: Start.Last?) -> String? {
        if choice.resume == .live { return nil }
        // Its CLI is not on this machine: that, before which session it was.
        if let gone = choice.lastGone {
            return String(localized: "\(gone), which the last supervisor used, is not installed on this machine.",
                          comment: "总控台：启动总管时，上次总管用的 CLI 在这台机器上找不到（没装），所以不再默认选它。%@ 是那个 CLI")
        }
        if choice.resume == .greyed, choice.why == .cliDiffers, let last,
           let was = cliName(key: last.lastCli, label: last.lastCliLabel),
           let picked = choice.picked,
           let now = cliName(key: picked, label: choice.clis.first { $0.key == picked }?.label) {
            return String(localized: "The last session was \(was)'s; \(now) can't go on with it.",
                          comment: "总控台：启动总管时选了和上次不同的 CLI，「接着上次的会话」变灰的原因。第一个是上次会话的 CLI，第二个是这次选的 CLI")
        }
        return resumeNote(choice.why)
    }

    /// The label of the CLI row.
    static var cliRowText: String {
        String(localized: "Agent CLI", comment: "总控台：启动总管时选用哪个 agent CLI 的那一行的标签")
    }

    /// What an option of the choice is called.
    static func optionText(_ session: Session) -> String {
        switch session {
        case .last:
            return String(localized: "Go on with the last session", comment: "总控台：启动总管时两选一的第一项，接着这个群上次总管的会话")
        case .new:
            return String(localized: "New session", comment: "总控台：启动总管时两选一的第二项，开一个新会话")
        }
    }

    /// One sentence about the supervisor this group last had: where it
    /// worked and which agent CLI it was. Nil when the core has no record
    /// of one, and then the right-hand side is what it was before.
    ///
    /// **The directory is said only when it is not the one on the line
    /// above.** `startingIn` is the directory this start will use -- the
    /// core's until the person picks another -- and it is drawn there
    /// already; said again it was the same path twice in three lines (the
    /// user, 2026-10-13). So it appears once the person has picked
    /// elsewhere, which is when it tells them something. And only when the
    /// core says the directory it names is that supervisor's
    /// (`cwd_from: last_supervisor`).
    ///
    /// The CLI is said only when it was written down: by the name the core
    /// gives for it (`cli_label`), and by its key when the core has none.
    static func lastSupervisorText(_ start: Start?, startingIn: String? = nil,
                                   home: String = NSHomeDirectory()) -> String? {
        guard let start, let last = start.last, last.heardMs != nil else { return nil }
        let directory = last.cwdIsTheLastSupervisors && !start.cwd.isEmpty && (startingIn ?? start.cwd) != start.cwd
            ? shownDirectory(start.cwd, home: home) : nil
        let cli = cliName(key: last.lastCli, label: last.lastCliLabel)
        switch (directory, cli) {
        case let (directory?, cli?):
            return String(localized: "The last supervisor worked in \(directory), using \(cli).",
                          comment: "总控台：没有总管的群，右栏写出上次总管在哪个目录、用的哪个 CLI。第一个是目录，第二个是 CLI")
        case let (directory?, nil):
            return String(localized: "The last supervisor worked in \(directory).",
                          comment: "总控台：没有总管的群，右栏写出上次总管在哪个目录（不知道它用的哪个 CLI）")
        case let (nil, cli?):
            return String(localized: "The last supervisor used \(cli).",
                          comment: "总控台：没有总管的群，右栏写出上次总管用的哪个 CLI（不知道它在哪个目录）")
        case (nil, nil):
            return nil
        }
    }

    /// What a CLI is written as: the core's name for it, and its key when
    /// the core has none. Nil when there is no CLI to name.
    static func cliName(key: String?, label: String?) -> String? {
        guard let key, !key.isEmpty else { return nil }
        if let label, !label.isEmpty { return label }
        return key
    }

    /// A directory as it is shown: the home directory as `~`. Here and not
    /// in the view, so that the sentence above is made without one.
    static func shownDirectory(_ path: String, home: String = NSHomeDirectory()) -> String {
        guard !path.isEmpty else {
            return String(localized: "Where the tab starts", comment: "总控台：启动总管时没有可用的默认目录，新标签页在哪就在哪")
        }
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// Why this start will not go on with the last session, in a sentence;
    /// nil where there is nothing worth saying -- it can, or there never
    /// was a supervisor to go on from. **Every reason the core gives has a
    /// case here**: one added there does not compile here until somebody
    /// says what the person is told.
    static func resumeNote(_ why: Start.ResumeWhy) -> String? {
        switch why {
        case .none, .noRecord:
            return nil
        case .noSession:
            return String(localized: "A new session will be started: the last supervisor's CLI never said which session it was in.",
                          comment: "总控台：启动总管时不能接着上次会话的原因：上次那个 CLI 没有报过会话")
        case .lastTryFailed:
            return String(localized: "A new session will be started: going on with the last one did not work the last time it was tried.",
                          comment: "总控台：启动总管时不能接着上次会话的原因：上一次接着旧会话启动没有成功")
        case .cliDiffers:
            return String(localized: "A new session will be started: the last session was in another CLI.",
                          comment: "总控台：启动总管时不能接着上次会话的原因：这次用的 CLI 和上次会话的不是同一个")
        case .clisUnread:
            return String(localized: "Checking whether the last session can be gone on with…",
                          comment: "总控台：启动总管时还不知道能不能接着上次会话：各个 CLI 的能力还没读到，读到以后这句会自己变")
        case .cliCannotResume:
            return String(localized: "A new session will be started: this CLI cannot go on with an earlier session.",
                          comment: "总控台：启动总管时不能接着上次会话的原因：这个 CLI 不支持接着以前的会话")
        case .sessionInUse:
            return String(localized: "A new session will be started: an open terminal is in the last session now.",
                          comment: "总控台：启动总管时不能接着上次会话的原因：上次的会话现在有一个开着的终端在用")
        }
    }
}
