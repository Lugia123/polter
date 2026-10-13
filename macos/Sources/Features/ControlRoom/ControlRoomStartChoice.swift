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
