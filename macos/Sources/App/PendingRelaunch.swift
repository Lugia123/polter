import Foundation

/// A fresh copy of this app, waiting to be opened once this one has exited.
///
/// The replacement waits for this pid to disappear before opening: this app
/// is a singleton over a socket, and launching first would leave two
/// instances briefly fighting over it. So the waiting process has to exist
/// *before* this one quits -- which means it exists while the quit can
/// still be called off. **It is held here so that calling it off can stop
/// it** (issue #12): left in a local, it outlived a cancelled quit and
/// reopened the app on whatever quit came next, hours later. Releasing a
/// `Process` does not stop its child; that was measured.
///
/// The bundle path is passed as an argument rather than spliced into the
/// script. A path with a quote or a space in it -- and on at least one
/// machine this checkout lives under a directory whose name contains a
/// space -- would otherwise turn into a broken command, or worse, a working
/// one that runs something else.
final class PendingRelaunch {
    /// `$0` of the waiting shell, so it can be found in a process listing
    /// (`pgrep -f polter-relaunch`).
    static let processName = "polter-relaunch"

    private let task: Process

    private init(task: Process) {
        self.task = task
    }

    /// Start waiting for `pid` to exit, then open `bundle` afresh.
    static func schedule(waitingFor pid: Int32, bundle: String) throws -> PendingRelaunch {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = [
            "-c",
            "while /bin/kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; exec /usr/bin/open -n \"$2\"",
            processName,
            String(pid),
            bundle,
        ]
        try task.run()
        return PendingRelaunch(task: task)
    }

    var isWaiting: Bool { task.isRunning }

    /// The quit was called off: stop waiting, so nothing reopens the app on
    /// a later, unrelated quit.
    func abandon() {
        guard task.isRunning else { return }
        task.terminate()
        task.waitUntilExit()
    }
}
