import Testing
import Foundation
@testable import Ghostty

/// Covers `PoltergeistLayoutParser` -- the half of `poltergeist_layout`
/// that needs no live `Ghostty.App` to test. The other half
/// (`TerminalController.applyToolLayout`'s tab-membership and duplicate
/// checks, and actually materializing surfaces) needs a real app instance
/// to construct `Ghostty.SurfaceView`s and isn't covered here; see that
/// method's mirror of `apply_layout` in `windows/host/src/tabs.rs` for the
/// logic being ported.
@Suite
struct PoltergeistLayoutShapeTests {
    private func parse(_ json: String) throws -> PoltergeistLayoutCell {
        let value = try JSONSerialization.jsonObject(with: Data(json.utf8))
        return try PoltergeistLayoutParser.parse(value)
    }

    private func parseError(_ json: String) -> String? {
        do {
            _ = try parse(json)
            return nil
        } catch let error as PoltergeistLayoutError {
            return error.message
        } catch {
            return "unexpected error type: \(error)"
        }
    }

    @Test func parsesAnExistingPane() throws {
        guard case .existing(let handle) = try parse(#"{"pane":"0x1a"}"#) else {
            Issue.record("expected .existing")
            return
        }
        #expect(handle == 0x1a)
    }

    @Test func parsesADecimalPaneId() throws {
        guard case .existing(let handle) = try parse(#"{"pane":"42"}"#) else {
            Issue.record("expected .existing")
            return
        }
        #expect(handle == 42)
    }

    @Test func parsesANewCellWithCwd() throws {
        guard case .new(let cwd) = try parse(#"{"new":{"cwd":"/tmp"}}"#) else {
            Issue.record("expected .new")
            return
        }
        #expect(cwd == "/tmp")
    }

    @Test func parsesANewCellWithoutCwd() throws {
        for json in [#"{"new":null}"#, #"{"new":{}}"#] {
            guard case .new(let cwd) = try parse(json) else {
                Issue.record("expected .new for \(json)")
                return
            }
            #expect(cwd == nil)
        }
    }

    @Test func parsesASplitWithDefaultRatio() throws {
        let cell = try parse(#"{"split":"h","left":{"new":null},"right":{"new":null}}"#)
        guard case .split(let direction, let ratio, _, _) = cell else {
            Issue.record("expected .split")
            return
        }
        #expect(direction == .horizontal)
        #expect(ratio == 0.5)
    }

    @Test func verticalSplitParsesToVerticalDirection() throws {
        let cell = try parse(#"{"split":"v","ratio":0.3,"left":{"new":null},"right":{"new":null}}"#)
        guard case .split(let direction, let ratio, _, _) = cell else {
            Issue.record("expected .split")
            return
        }
        #expect(direction == .vertical)
        #expect(ratio == 0.3)
    }

    // MARK: - Refusals (the floor: each of these must actually be a red path)

    @Test func ratioAtOrBelowZeroIsRefused() {
        #expect(parseError(#"{"split":"h","ratio":0,"left":{"new":null},"right":{"new":null}}"#) != nil)
        #expect(parseError(#"{"split":"h","ratio":-0.1,"left":{"new":null},"right":{"new":null}}"#) != nil)
    }

    @Test func ratioAtOrAboveOneIsRefused() {
        #expect(parseError(#"{"split":"h","ratio":1,"left":{"new":null},"right":{"new":null}}"#) != nil)
        #expect(parseError(#"{"split":"h","ratio":1.5,"left":{"new":null},"right":{"new":null}}"#) != nil)
    }

    @Test func ratioInRangeIsAccepted() throws {
        _ = try parse(#"{"split":"h","ratio":0.01,"left":{"new":null},"right":{"new":null}}"#)
        _ = try parse(#"{"split":"h","ratio":0.99,"left":{"new":null},"right":{"new":null}}"#)
    }

    @Test func unknownSplitAxisIsRefused() {
        #expect(parseError(#"{"split":"diagonal","left":{"new":null},"right":{"new":null}}"#) != nil)
    }

    @Test func splitMissingASideIsRefused() {
        #expect(parseError(#"{"split":"h","left":{"new":null}}"#) != nil)
        #expect(parseError(#"{"split":"h","right":{"new":null}}"#) != nil)
    }

    @Test func aCellThatIsNoneOfTheThreeKindsIsRefused() {
        #expect(parseError(#"{"nonsense":true}"#) != nil)
    }

    @Test func aNonObjectCellIsRefused() {
        #expect(parseError(#""just a string""#) != nil)
    }

    @Test func aPaneIdThatIsNotANumberIsRefused() {
        #expect(parseError(#"{"pane":"not-a-number"}"#) != nil)
    }

    // MARK: - A stack

    @Test func aStackIsOnePaneHoldingItsMembersWithTheFirstInFront() throws {
        let cell = try parse(#"{"stack":[{"pane":"0x1"},{"new":{"cwd":"/work"}},{"pane":"0x2"}]}"#)
        guard case .stack(let members, let shown) = cell else {
            Issue.record("not a stack: \(cell)")
            return
        }
        #expect(shown == 0)
        #expect(members.count == 3)
        if case .existing(let handle) = members[0] { #expect(handle == 0x1) } else { Issue.record("member 0") }
        if case .new(let cwd) = members[1] { #expect(cwd == "/work") } else { Issue.record("member 1") }
        if case .existing(let handle) = members[2] { #expect(handle == 0x2) } else { Issue.record("member 2") }
    }

    @Test func whichMemberIsInFrontIsSaidByItsPlace() throws {
        let cell = try parse(#"{"stack":[{"pane":"0x1"},{"pane":"0x2"},{"new":null}],"shown":2}"#)
        guard case .stack(_, let shown) = cell else {
            Issue.record("not a stack")
            return
        }
        #expect(shown == 2)
        // A place that is not one of the members, or not a whole number.
        for bad in ["3", "-1", "1.5", "\"1\"", "true", "null"] {
            #expect(parseError(#"{"stack":[{"pane":"0x1"},{"pane":"0x2"},{"new":null}],"shown":"# + bad + "}") != nil, "\(bad)")
        }
    }

    @Test func aStackOfOneOrOfNoneIsRefused() {
        #expect(parseError(#"{"stack":[{"pane":"0x1"}]}"#) != nil)
        #expect(parseError(#"{"stack":[]}"#) != nil)
        #expect(parseError(#"{"stack":{"pane":"0x1"}}"#) != nil)
    }

    @Test func aStackHoldsTerminalsNotSplitsOrStacks() {
        #expect(parseError(#"""
        {"stack":[{"pane":"0x1"},{"split":"h","left":{"pane":"0x2"},"right":{"new":null}}]}
        """#) != nil)
        #expect(parseError(#"{"stack":[{"pane":"0x1"},{"stack":[{"pane":"0x2"},{"new":null}]}]}"#) != nil)
        // And a member that is wrong in itself is the stack being wrong.
        #expect(parseError(#"{"stack":[{"pane":"0x1"},{"pane":"not-a-number"}]}"#) != nil)
    }

    @Test func aStackIsACellLikeAnyOtherInsideASplit() throws {
        let cell = try parse(#"""
        {"split":"h","ratio":0.4,
         "left":{"pane":"0x1"},
         "right":{"stack":[{"pane":"0x2"},{"pane":"0x3"}],"shown":1}}
        """#)
        guard case .split(_, _, _, let right) = cell, case .stack(let members, let shown) = right else {
            Issue.record("the right side is not a stack")
            return
        }
        #expect(members.count == 2)
        #expect(shown == 1)
        // Every terminal it names is one the tab has to hold: the ones
        // behind as much as the one in front.
        var out: [UInt] = []
        cell.collectExisting(into: &out)
        #expect(out == [0x1, 0x2, 0x3])
    }

    // MARK: - collectExisting

    @Test func collectExistingFindsHandlesAtEveryDepthIncludingDuplicates() throws {
        let cell = try parse(#"""
        {"split":"h",
         "left":{"pane":"0x1"},
         "right":{"split":"v","left":{"pane":"0x2"},"right":{"pane":"0x1"}}}
        """#)
        var out: [UInt] = []
        cell.collectExisting(into: &out)
        #expect(out == [0x1, 0x2, 0x1])
    }
}
