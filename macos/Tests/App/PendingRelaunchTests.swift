import Testing
import Foundation
@testable import Ghostty

/// Issue #12: the process that reopens the app after a restart must stop
/// when the restart is called off, or it reopens the app on the next,
/// unrelated quit.
@Suite
struct PendingRelaunchTests {
    /// A stand-in for this app's pid: something that stays alive until the
    /// test ends it.
    private func standIn() throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["60"]
        try p.run()
        return p
    }

    @Test func abandoningStopsTheWaitingProcess() throws {
        let app = try standIn()
        defer { app.terminate() }
        // A bundle that does not exist: if the helper ever did reach
        // `open -n`, nothing would be launched.
        let pending = try PendingRelaunch.schedule(waitingFor: app.processIdentifier, bundle: "/nonexistent/Polter.app")
        #expect(pending.isWaiting)

        pending.abandon()
        #expect(!pending.isWaiting)
    }

    @Test func abandoningTwiceIsHarmless() throws {
        let app = try standIn()
        defer { app.terminate() }
        let pending = try PendingRelaunch.schedule(waitingFor: app.processIdentifier, bundle: "/nonexistent/Polter.app")
        pending.abandon()
        pending.abandon()
        #expect(!pending.isWaiting)
    }
}
