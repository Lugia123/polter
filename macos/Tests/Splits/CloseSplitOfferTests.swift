import AppKit
import Testing
@testable import Ghostty

/// **Close Split** is offered when there is a split to close, and not otherwise.
///
/// The row closes one pane and leaves the tab. On a tab with a single pane
/// there is no such thing: closing that pane closes the tab, which is what
/// `Close Tab` next to it is for. So the question this answers is not
/// cosmetic -- a row that stayed enabled there would do its neighbour's job
/// under its own name.
///
/// Asked of the tree rather than of a running window: a live `SurfaceView`
/// needs an app, a window and a pty, none of which a test has, and the
/// decision does not depend on any of them.
@MainActor
struct CloseSplitOfferTests {
    @Test func aTabWithOnePaneHasNoSplitToClose() {
        let tree = SplitTree<MockView>(view: MockView())
        #expect(Ghostty.SurfaceView.closeSplitIsOffered(in: tree) == false)
    }

    @Test func aSplitTabHasOne() throws {
        let (tree, _, _) = try SplitTreeTests.makeHorizontalSplit()
        #expect(Ghostty.SurfaceView.closeSplitIsOffered(in: tree) == true)
    }

    @Test func anEmptyTreeHasNone() {
        let tree = SplitTree<MockView>()
        #expect(Ghostty.SurfaceView.closeSplitIsOffered(in: tree) == false)
    }

    /// No tree at all -- the surface is in no window, or in a window that is
    /// not a terminal controller's. The row is greyed rather than guessed at.
    @Test func noTreeMeansNone() {
        #expect(Ghostty.SurfaceView.closeSplitIsOffered(in: nil as SplitTree<MockView>?) == false)
    }
}
