import AppKit
import Foundation
import Testing
@testable import Ghostty

/// A pane that holds more than one terminal (control-room.md, 12.6.2): the
/// table beside the tree, and the four things that change it.
///
/// Nothing in the application can make a stack yet. These are the rules it
/// will be held to when something can -- above all the one the whole design
/// turns on: **a terminal put behind another is still in the tree**, for
/// every question asked of the tree and after every operation on it. The
/// ones behind have no pane to show that they are missing.
struct SplitStackTests {
    typealias Tree = SplitTree<MockView>

    /// Three panes, a | (b over c), and a fourth and fifth terminal to stack.
    private struct Fixture {
        let a = MockView(), b = MockView(), c = MockView(), d = MockView(), e = MockView()
        let tree: Tree

        init() throws {
            var tree = Tree(view: a)
            tree = try tree.inserting(view: b, at: a, direction: .right)
            tree = try tree.inserting(view: c, at: b, direction: .down)
            self.tree = tree
        }
    }

    /// What has to be true of any tree, whatever was done to it.
    private func sound(_ tree: Tree, _ comment: Comment? = nil, at: SourceLocation = #_sourceLocation) {
        let shown = tree.shownLeaves()
        for stack in tree.stacks {
            #expect(stack.members.count > 1, comment, sourceLocation: at)
            let front = stack.members.filter { $0.id == stack.shown }
            #expect(front.count == 1, comment, sourceLocation: at)
            #expect(shown.contains { $0 === front.first }, comment, sourceLocation: at)
        }
        let all = tree.members().map { ObjectIdentifier($0) }
        #expect(Set(all).count == all.count, comment, sourceLocation: at)
        for view in shown { #expect(all.contains(ObjectIdentifier(view)), comment, sourceLocation: at) }
    }

    private func ids(_ views: [MockView]) -> [UUID] { views.map(\.id) }

    /// The tree's one stack. Required, not indexed: a tree that has lost
    /// its stack fails here, on this line, and does not take the run down.
    private func only(_ tree: Tree, at: SourceLocation = #_sourceLocation) throws -> Tree.Stack {
        try #require(tree.stacks.count == 1 ? tree.stacks.first : nil, sourceLocation: at)
    }

    /// What an operation refused with; nil when it went through. (Not
    /// `#expect(throws:)`: that hands the tree out of the closure, and the
    /// application's own build does not let a view cross that line.)
    private func refusal(_ body: () throws -> Void) -> Tree.SplitError? {
        do {
            try body()
            return nil
        } catch let error as Tree.SplitError {
            return error
        } catch {
            return nil
        }
    }

    // MARK: Stacking

    @Test func stackingPutsTheNewTerminalInFrontAndKeepsTheOneItCovered() throws {
        let f = try Fixture()
        let tree = try f.tree.stacking(f.d, onto: f.b)
        sound(tree)

        // The pane shows the new one; the tree has the same three panes.
        #expect(ids(tree.shownLeaves()) == ids([f.a, f.d, f.c]))
        #expect(tree.isShown(f.d))
        #expect(!tree.isShown(f.b))
        #expect(tree.shown(for: f.b) === f.d)

        // And the one behind is still in the tree, for every way of asking.
        #expect(ids(tree.members()) == ids([f.a, f.b, f.d, f.c]))
        #expect(ids(Array(tree)) == ids([f.a, f.b, f.d, f.c]))
        #expect(tree.count == 4)
        #expect(tree.contains { $0 === f.b })
        #expect(tree.first { $0.id == f.b.id } === f.b)

        // One stack, in the order of its tabs: the new one last.
        #expect(tree.stacks.count == 1)
        #expect(ids((try only(tree)).members) == ids([f.b, f.d]))
        #expect((try only(tree)).shown == f.d.id)
    }

    @Test func stackingOntoATerminalThatIsBehindGoesIntoTheSamePane() throws {
        let f = try Fixture()
        var tree = try f.tree.stacking(f.d, onto: f.b)
        // `b` is behind `d` now; naming it still means its pane.
        tree = try tree.stacking(f.e, onto: f.b)
        sound(tree)
        #expect(tree.stacks.count == 1)
        #expect(ids((try only(tree)).members) == ids([f.b, f.d, f.e]))
        #expect(ids(tree.shownLeaves()) == ids([f.a, f.e, f.c]))
    }

    @Test func stackingRefusesATerminalAlreadyInTheTreeAndATargetThatIsNot() throws {
        let f = try Fixture()
        #expect(refusal { _ = try f.tree.stacking(f.a, onto: f.b) } != nil)
        #expect(refusal { _ = try f.tree.stacking(f.d, onto: f.e) } != nil)
        // Behind counts as already in it.
        let tree = try f.tree.stacking(f.d, onto: f.b)
        #expect(refusal { _ = try tree.stacking(f.b, onto: f.a) } != nil)
    }

    @Test func twoPanesEachKeepTheirOwnStack() throws {
        let f = try Fixture()
        var tree = try f.tree.stacking(f.d, onto: f.a)
        tree = try tree.stacking(f.e, onto: f.c)
        sound(tree)
        #expect(tree.stacks.count == 2)
        #expect(ids(tree.members()) == ids([f.a, f.d, f.b, f.c, f.e]))
        #expect(ids(tree.shownLeaves()) == ids([f.d, f.b, f.e]))
        #expect(tree.stack(of: f.b) == nil)
    }

    // MARK: Showing

    @Test func showingBringsOneFromBehindToTheFrontWithoutReorderingTheTabs() throws {
        let f = try Fixture()
        var tree = try f.tree.stacking(f.d, onto: f.b)
        tree = try tree.stacking(f.e, onto: f.b)

        tree = try tree.showing(f.b)
        sound(tree)
        #expect(ids(tree.shownLeaves()) == ids([f.a, f.b, f.c]))
        #expect(ids((try only(tree)).members) == ids([f.b, f.d, f.e]))
        #expect((try only(tree)).shown == f.b.id)
        #expect(tree.count == 5)

        // Showing what is shown changes nothing.
        let again = try tree.showing(f.b)
        #expect(ids(again.shownLeaves()) == ids(tree.shownLeaves()))
        #expect((try only(again)).shown == f.b.id)
    }

    @Test func showingRefusesAPaneOfOneAndATerminalThatIsNotThere() throws {
        let f = try Fixture()
        #expect(refusal { _ = try f.tree.showing(f.a) } == .notStacked)
        #expect(refusal { _ = try f.tree.showing(f.d) } == .viewNotFound)
    }

    // MARK: Removing

    @Test func removingTheShownOneLetsTheNextTabTakeItsPlaceInTheSamePane() throws {
        let f = try Fixture()
        var tree = try f.tree.stacking(f.d, onto: f.b)
        tree = try tree.stacking(f.e, onto: f.b)
        tree = try tree.showing(f.d)

        // b, [d], e: closing d shows e, the tab after it.
        let node = try #require(tree.root?.node(view: f.d))
        #expect(ids(tree.removed(by: node)) == ids([f.d]))
        let after = tree.removing(node)
        sound(after)
        #expect(ids(after.shownLeaves()) == ids([f.a, f.e, f.c]))
        #expect(ids(after.members()) == ids([f.a, f.b, f.e, f.c]))
        #expect(!after.contains { $0 === f.d })

        // b, [e]: closing the last tab shows the one before it, and with one
        // left the pane is an ordinary leaf again.
        let last = after.removing(try #require(after.root?.node(view: f.e)))
        sound(last)
        #expect(ids(last.shownLeaves()) == ids([f.a, f.b, f.c]))
        #expect(last.stacks.isEmpty)
    }

    @Test func removingOneFromBehindLeavesThePaneShowingWhatItShowed() throws {
        let f = try Fixture()
        var tree = try f.tree.stacking(f.d, onto: f.b)
        tree = try tree.stacking(f.e, onto: f.b)

        let after = try tree.removing(member: f.b)
        sound(after)
        #expect(ids(after.shownLeaves()) == ids([f.a, f.e, f.c]))
        #expect(ids((try only(after)).members) == ids([f.d, f.e]))
        #expect(!after.contains { $0 === f.b })
        #expect(refusal { _ = try after.removing(member: f.b) } == .viewNotFound)
    }

    @Test func aTreeWhoseStackWasTakenApartIsStoredAsItAlwaysWas() throws {
        // The promise the stored form rests on: no stack, same bytes.
        let one = MockView(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let two = MockView(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
        let plain = Tree(view: one)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let before = try encoder.encode(plain)

        let stacked = try plain.stacking(two, onto: one)
        // With a stack there is no form to store it in yet: refused, not
        // written without the one behind.
        #expect(throws: EncodingError.self) { try encoder.encode(stacked) }

        let apart = try stacked.removing(member: two)
        #expect(apart.stacks.isEmpty)
        #expect(try encoder.encode(apart) == before)
        let text = try #require(String(bytes: before, encoding: .utf8))
        #expect(text == #"{"root":{"view":{"id":"00000000-0000-0000-0000-000000000001"}},"version":1}"#)
    }

    @Test func removingASplitTakesEveryTerminalUnderItTheOnesBehindToo() throws {
        let f = try Fixture()
        let tree = try f.tree.stacking(f.d, onto: f.b)
        // The right-hand split: (b, [d]) over c.
        guard case .split(let root) = tree.root else {
            Issue.record("the fixture is a split")
            return
        }
        #expect(ids(tree.removed(by: root.right)) == ids([f.b, f.d, f.c]))
        #expect(ids(tree.members(under: root.right)) == ids([f.b, f.d, f.c]))

        let after = tree.removing(root.right)
        sound(after)
        #expect(ids(after.members()) == ids([f.a]))
        #expect(after.stacks.isEmpty)
    }

    @Test func removingAPaneOfOneIsWhatItAlwaysWas() throws {
        let f = try Fixture()
        let tree = try f.tree.stacking(f.d, onto: f.b)
        let after = tree.removing(try #require(tree.root?.node(view: f.a)))
        sound(after)
        #expect(ids(after.shownLeaves()) == ids([f.d, f.c]))
        // The stack in another pane is untouched.
        #expect(ids(after.members()) == ids([f.b, f.d, f.c]))
    }

    // MARK: Unstacking

    @Test func unstackingMakesItAPaneOfItsOwnBesideThePaneItWasIn() throws {
        let f = try Fixture()
        var tree = try f.tree.stacking(f.d, onto: f.b)
        tree = try tree.stacking(f.e, onto: f.b)

        // From behind: the pane goes on showing e; d appears to its right.
        let behind = try tree.unstacking(f.d, direction: .right)
        sound(behind)
        #expect(ids(behind.shownLeaves()) == ids([f.a, f.e, f.d, f.c]))
        #expect(ids((try only(behind)).members) == ids([f.b, f.e]))
        #expect(behind.count == 5)

        // The shown one: the next tab takes the pane, and it lands on the left.
        let front = try tree.unstacking(f.e, direction: .left)
        sound(front)
        #expect(ids(front.shownLeaves()) == ids([f.a, f.e, f.d, f.c]))
        #expect(ids((try only(front)).members) == ids([f.b, f.d]))

        // Out of a stack of two: no stack is left, and nothing is lost.
        let two = try f.tree.stacking(f.d, onto: f.b)
        let apart = try two.unstacking(f.b, direction: .down)
        sound(apart)
        #expect(apart.stacks.isEmpty)
        #expect(ids(apart.shownLeaves()) == ids([f.a, f.d, f.b, f.c]))
    }

    @Test func unstackingRefusesAPaneOfOneAndATerminalThatIsNotThere() throws {
        let f = try Fixture()
        #expect(refusal { _ = try f.tree.unstacking(f.a, direction: .right) } == .notStacked)
        #expect(refusal { _ = try f.tree.unstacking(f.d, direction: .right) } == .viewNotFound)
    }

    // MARK: A tab dropped onto a pane

    /// A tab of three panes, x | (y over z), with w stacked behind z: four
    /// terminals in the order x, y, z, w. The keyboard is on y.
    private struct DroppedTab {
        let x = MockView(), y = MockView(), z = MockView(), w = MockView()
        let tree: Tree

        init() throws {
            var tree = Tree(view: x)
            tree = try tree.inserting(view: y, at: x, direction: .right)
            tree = try tree.inserting(view: z, at: y, direction: .down)
            tree = try tree.stacking(w, onto: z)
            tree = try tree.showing(z)
            self.tree = tree
        }
    }

    @Test func aTabOfSeveralDroppedOnAPaneOfOneBecomesOneStackedPane() throws {
        let target = MockView()
        let t = try DroppedTab()
        let tree = try Tree(view: target).inserting(tab: t.tree, showing: t.y, at: target, direction: .left)
        sound(tree)

        // Two panes: the new one on the side it was dropped, showing y.
        #expect(ids(tree.shownLeaves()) == ids([t.y, target]))
        // Every terminal of the tab is in it, in the tab's order.
        let stack = try only(tree)
        #expect(ids(stack.members) == ids([t.x, t.y, t.z, t.w]))
        #expect(stack.shown == t.y.id)
        #expect(tree.count == 5)
    }

    @Test func aTabOfSeveralDroppedOnOnePaneOfSeveralStacksBesideThatPane() throws {
        let f = try Fixture()
        let t = try DroppedTab()
        let tree = try f.tree.inserting(tab: t.tree, showing: t.y, at: f.b, direction: .down)
        sound(tree)
        #expect(ids(tree.shownLeaves()) == ids([f.a, f.b, t.y, f.c]))
        let stack = try only(tree)
        #expect(ids(stack.members) == ids([t.x, t.y, t.z, t.w]))
        #expect(stack.shown == t.y.id)
        #expect(ids(tree.members()) == ids([f.a, f.b, t.x, t.y, t.z, t.w, f.c]))
    }

    @Test func aTabOfOneDroppedOnAPaneIsAnOrdinaryPane() throws {
        let x = MockView()
        let tab = Tree(view: x)

        let target = MockView()
        let one = try Tree(view: target).inserting(tab: tab, showing: x, at: target, direction: .right)
        sound(one)
        #expect(ids(one.shownLeaves()) == ids([target, x]))
        #expect(one.stacks.isEmpty)

        let f = try Fixture()
        let several = try f.tree.inserting(tab: tab, showing: x, at: f.a, direction: .up)
        sound(several)
        #expect(ids(several.shownLeaves()) == ids([x, f.a, f.b, f.c]))
        #expect(several.stacks.isEmpty)
    }

    @Test func aTabDroppedOnAStackedPaneGoesBesideThatPaneAndLeavesItsStack() throws {
        let f = try Fixture()
        let stacked = try f.tree.stacking(f.d, onto: f.b)
        let t = try DroppedTab()
        // Named by the terminal behind: still that pane.
        let tree = try stacked.inserting(tab: t.tree, showing: t.w, at: f.b, direction: .right)
        sound(tree)
        #expect(ids(tree.shownLeaves()) == ids([f.a, f.d, t.w, f.c]))
        #expect(tree.stacks.count == 2)
        #expect(ids(tree.stack(of: f.b)?.members ?? []) == ids([f.b, f.d]))
        #expect(ids(tree.stack(of: t.x)?.members ?? []) == ids([t.x, t.y, t.z, t.w]))
        #expect(tree.stack(of: t.x)?.shown == t.w.id)
    }

    @Test func aTabDropRefusesATerminalAlreadyHereAShownOneNotInTheTabAndATargetNotHere() throws {
        let f = try Fixture()
        let t = try DroppedTab()
        #expect(refusal { _ = try f.tree.inserting(tab: t.tree, showing: f.a, at: f.b, direction: .left) }
            == .viewNotFound)
        #expect(refusal { _ = try f.tree.inserting(tab: t.tree, showing: t.x, at: f.d, direction: .left) }
            == .viewNotFound)
        #expect(refusal { _ = try f.tree.inserting(tab: f.tree, showing: f.a, at: f.b, direction: .left) }
            == .viewAlreadyPresent)
    }

    // MARK: Zoom

    @Test func theZoomStaysOnThePaneWhenWhatItShowsChanges() throws {
        let f = try Fixture()
        // The pane itself is zoomed.
        var tree = f.tree.zooming(f.tree.root?.node(view: f.b))
        tree = try tree.stacking(f.d, onto: f.b)
        #expect(tree.zoomed == .leaf(view: f.d))
        tree = try tree.showing(f.b)
        #expect(tree.zoomed == .leaf(view: f.b))
        tree = tree.removing(try #require(tree.root?.node(view: f.b)))
        #expect(tree.zoomed == .leaf(view: f.d))

        // A split that holds the pane is zoomed: still that split.
        guard case .split(let root) = f.tree.root else {
            Issue.record("the fixture is a split")
            return
        }
        let wide = try f.tree.zooming(root.right).stacking(f.d, onto: f.c)
        #expect(ids(wide.zoomed?.shownLeaves() ?? []) == ids([f.b, f.d]))
        #expect(wide.contains(try #require(wide.zoomed)))
    }

    // MARK: Every other operation keeps the stacks

    @Test func nothingElseThatReturnsATreeDropsTheTerminalsBehind() throws {
        let f = try Fixture()
        let tree = try f.tree.stacking(f.d, onto: f.b)
        let want = ids([f.a, f.b, f.d, f.c])
        guard case .split(let root) = tree.root else {
            Issue.record("the fixture is a split")
            return
        }

        let inserted = try tree.inserting(view: f.e, at: f.c, direction: .right)
        sound(inserted, "inserting")
        #expect(ids(inserted.members()) == ids([f.a, f.b, f.d, f.c, f.e]))

        let equal = tree.equalized()
        sound(equal, "equalized")
        #expect(ids(equal.members()) == want)

        let resized = try tree.resizing(
            node: try #require(tree.root?.node(view: f.d)), by: 10, in: .left,
            with: CGRect(x: 0, y: 0, width: 800, height: 600))
        sound(resized, "resizing")
        #expect(ids(resized.members()) == want)

        let replaced = try tree.replacing(node: .split(root), with: .split(root).resizing(to: 0.3))
        sound(replaced, "replacing")
        #expect(ids(replaced.members()) == want)

        let zoomed = tree.zooming(tree.root?.node(view: f.a)).zooming(nil)
        sound(zoomed, "zooming")
        #expect(ids(zoomed.members()) == want)

        // Replacing the pane itself by another view would strand the one
        // behind it: refused.
        #expect(refusal { _ = try tree.replacing(node: .leaf(view: f.d), with: .leaf(view: f.e)) }
            == .stackedPaneReplaced)
        // A pane with nothing behind it may be.
        let swapped = try tree.replacing(node: .leaf(view: f.a), with: .leaf(view: f.e))
        sound(swapped, "replacing a pane of one")
        #expect(ids(swapped.members()) == ids([f.e, f.b, f.d, f.c]))
    }

    @Test func aTreeWithNoStacksAnswersEveryQuestionAsItDidBefore() throws {
        // What step 1 changes for the application as it is: nothing.
        let f = try Fixture()
        #expect(f.tree.stacks.isEmpty)
        #expect(ids(f.tree.members()) == ids(f.tree.shownLeaves()))
        #expect(ids(Array(f.tree)) == ids([f.a, f.b, f.c]))
        #expect(f.tree.count == 3)
        #expect(f.tree.isShown(f.a))
        #expect(f.tree.shown(for: f.d) == nil)
        let node = try #require(f.tree.root?.node(view: f.b))
        #expect(ids(f.tree.removed(by: node)) == ids([f.b]))
        #expect(ids(f.tree.removing(node).members()) == ids([f.a, f.c]))
        #expect(ids((try f.tree.removing(member: f.b)).members()) == ids([f.a, f.c]))
    }
}
