import Testing

@testable import Ghostty

/// **The `CHAT_JUMP_*` wait rule** (design §26's instrument). The change it
/// pins: a jump used to fire on a timer, so it measured the clamp
/// (`index=39 wanted=500 clamped=1`) -- the index only exists once
/// `feed.rows` holds it, so the row arriving is the moment and the
/// millisecond value is the cap.
///
/// The wiring (environment -> poller -> `feed.loadOlder` -> `jump(to:)`) needs
/// a surface and is not in this package; what is here is the table it reads.
@Suite("The chat's debug jump")
struct ControlRoomChatDebugJumpTests {
    private func armed(
        _ env: [String: String]
    ) throws -> ControlRoomChatDebugJump {
        try #require(ControlRoomChatDebugJump(env: env))
    }

    private func waitingFor500() throws -> ControlRoomChatDebugJump {
        try armed(["CHAT_JUMP_AFTER_MS": "8000", "CHAT_JUMP_TO_INDEX": "500"])
    }

    /// The row is not in what is loaded: wait, do not jump at the clamp.
    @Test func testAnIndexNotLoadedYetWaits() throws {
        let plan = try waitingFor500()
        #expect(plan.step(rows: 200, elapsed: 7.9) == .wait)
    }

    /// `rows == wanted` is one short: index 500 needs 501 rows.
    @Test func testTheRowItselfIsTheLastRowThatMakesTheIndexExist() throws {
        let plan = try waitingFor500()
        #expect(plan.step(rows: 500, elapsed: 0.2) == .wait)
    }

    /// The page landed: jump at once, and the log's two numbers agree.
    @Test func testTheRowArrivingIsTheMoment() throws {
        let plan = try waitingFor500()
        #expect(plan.step(rows: 501, elapsed: 0.2) == .jump(index: 500, clamped: false))
    }

    /// The cap is a fallback: it jumps where it can and says it clamped.
    @Test func testTheCapJumpsClampedWhenTheRowNeverArrives() throws {
        let plan = try waitingFor500()
        #expect(plan.step(rows: 40, elapsed: 8) == .jump(index: 39, clamped: true))
    }

    /// The cap with nothing loaded says there is no index to jump to.
    @Test func testTheCapWithNoRowsSaysSo() throws {
        let plan = try waitingFor500()
        #expect(plan.step(rows: 0, elapsed: 8) == .nothingLoaded)
    }

    /// A wanted index larger than what exists at the cap clamps to the last
    /// row, and the last row is never reported as the row asked for.
    @Test func testAnIndexBeyondTheGroupClampsToTheLastRow() throws {
        let plan = try armed(["CHAT_JUMP_AFTER_MS": "1000", "CHAT_JUMP_TO_INDEX": "5000"])
        #expect(plan.step(rows: 1200, elapsed: 1) == .jump(index: 1199, clamped: true))
    }

    /// `CHAT_JUMP_AFTER_MS` alone keeps the old shape: a timed jump to the
    /// oldest loaded row, no waiting on an index.
    @Test func testAfterMsAloneStaysAPlainTimer() throws {
        let plan = try armed(["CHAT_JUMP_AFTER_MS": "2000"])
        #expect(plan.step(rows: 400, elapsed: 1.9) == .wait)
        #expect(plan.step(rows: 400, elapsed: 2) == .jump(index: 0, clamped: false))
        #expect(plan.step(rows: 0, elapsed: 2) == .nothingLoaded)
    }

    /// The hook is off unless armed: no milliseconds, no reading, no timer.
    @Test func testTheHookIsNotArmedWithoutTheMillisecond() {
        #expect(ControlRoomChatDebugJump(env: [:]) == nil)
        #expect(ControlRoomChatDebugJump(env: ["CHAT_JUMP_TO_INDEX": "500"]) == nil)
        #expect(ControlRoomChatDebugJump(env: ["CHAT_JUMP_AFTER_MS": "-1"]) == nil)
        #expect(ControlRoomChatDebugJump(env: ["CHAT_JUMP_AFTER_MS": "abc"]) == nil)
    }

    /// A negative index is the first row, as the view's clamp always made it.
    @Test func testANegativeIndexIsTheFirstRow() throws {
        let plan = try armed(["CHAT_JUMP_AFTER_MS": "0", "CHAT_JUMP_TO_INDEX": "-3"])
        #expect(plan.wanted == 0)
        #expect(plan.step(rows: 10, elapsed: 0) == .jump(index: 0, clamped: false))
    }
}
