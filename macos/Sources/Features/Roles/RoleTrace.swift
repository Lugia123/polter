import Foundation
import OSLog

/// A diagnosis of task 2806, and not a part of the feature: the role page's
/// CLI tick, the save it goes into, and the catalog that comes back.
///
/// **Off unless the process was started with `POLTER_ROLE_TRACE=1` in its
/// environment.** One variable, read from `ProcessInfo.environment`: it is
/// the test instance's own environment, so nothing is written anywhere, and
/// it is not a launch argument -- the core's argument parser
/// (`src/cli/args.zig`) only accepts `--` options, so `-Name value` would be
/// refused or diagnosed there. No row, switch or setting turns it on.
///
/// **Remove it whole** by deleting this file and every `RoleTrace.emit`
/// line; nothing else refers to it. What it writes is the role's key, its
/// CLI keys, booleans and an error's name -- never a name, a description,
/// instructions, arguments, variables, a token or any JSON.
///
/// `event=` counts emitted lines, so a log read back has the order they
/// were written in; `save=` counts saves and is on the lines of one save,
/// which is the thing to follow. One save is several events. **While off
/// nothing is counted or formatted**: the message is built only after the
/// switch is found on.
@MainActor
enum RoleTrace {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.mitchellh.ghostty",
        category: "role-trace")

    /// The one variable, never the rest of the environment: this is read and
    /// compared, not listed or written out anywhere.
    static let on = ProcessInfo.processInfo.environment["POLTER_ROLE_TRACE"] == "1"

    private static var eventNo = 0
    private static var saveNo = 0

    /// 0 while off, and nothing is counted then.
    static func nextEvent() -> Int {
        guard on else { return 0 }
        eventNo += 1
        return eventNo
    }

    /// 0 while off, and nothing is counted then.
    static func nextSave() -> Int {
        guard on else { return 0 }
        saveNo += 1
        return saveNo
    }

    /// A role's CLI keys, sorted, as one field of a line: `-` for no role.
    static func clis(_ role: Role?) -> String {
        guard let role else { return "-" }
        return keys(role.clis.map(\.cli))
    }

    static func keys(_ list: [String]) -> String {
        list.sorted().joined(separator: ",")
    }

    /// Built only when on: the message is an autoclosure so that a build
    /// with the diagnosis off pays nothing for it.
    static func emit(_ what: @autoclosure () -> String) {
        guard on else { return }
        logger.notice("\(what(), privacy: .public)")
    }
}
