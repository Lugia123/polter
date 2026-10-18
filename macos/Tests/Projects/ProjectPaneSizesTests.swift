import CoreGraphics
import Testing
@testable import Ghostty

/// The sizes a project page's panes are created at, before they exist
/// (#47). The numbers are the ones measured on a real window: `arr2`'s
/// second window, 1200x720 with a 32pt titlebar and the debug build's 32pt
/// band over the tree, laid out its panes at 588x608, 588x284 and 588x284
/// (AX frames, which drop the half point the right column has).
struct ProjectPaneSizesTests {
    private static func leaf(_ n: Int) -> ProjectNode {
        .leaf(cwd: "/\(n)", title: "t\(n)", titleChosen: false, history: "", scrollback: "\(n).snap", bySupervisor: false, supervisorSeat: false, color: .none, workersRefused: false, shielded: false, agent: .none)
    }

    /// 1 | (2 / 3), both splits at the middle.
    private static let threePanes = ProjectNode.split(
        direction: .horizontal, ratio: 0.5, left: leaf(1),
        right: .split(direction: .vertical, ratio: 0.5, left: leaf(2), right: leaf(3)))

    @Test func framedPanesAreTheSizesTheWindowLaidOut() {
        let sizes = ProjectPaneSizes.sizes(of: Self.threePanes, in: CGSize(width: 1200, height: 656), framed: true)
        #expect(sizes == [CGSize(width: 588, height: 608), CGSize(width: 588.5, height: 284), CGSize(width: 588.5, height: 284.5)])
    }

    @Test func pixelsAreWhatTheViewHandsTheCore() {
        let p = ProjectPaneSizes.pixels(CGSize(width: 588.5, height: 284.5), scale: 2)
        #expect(p.width == 1177)
        #expect(p.height == 569)
    }

    /// Without frames the panes meet at the divider: no edge, no title band.
    @Test func unframedPanesMeetAtTheDivider() {
        let sizes = ProjectPaneSizes.sizes(of: Self.threePanes, in: CGSize(width: 1200, height: 656), framed: false)
        #expect(sizes == [CGSize(width: 599, height: 656), CGSize(width: 600.5, height: 327), CGSize(width: 600.5, height: 328.5)])
    }

    /// A pane alone wears no frame, framed or not.
    @Test func aPaneAloneIsTheWholeArea() {
        let sizes = ProjectPaneSizes.sizes(of: Self.leaf(1), in: CGSize(width: 1200, height: 656), framed: true)
        #expect(sizes == [CGSize(width: 1200, height: 656)])
    }

    /// A stack's strip depends on what the core says of its terminals, so
    /// no size is guessed -- but there is still one entry for every
    /// terminal `building` makes, or the sizes would go to the wrong panes.
    @Test func aTreeWithAStackIsNotSizedButIsCounted() {
        let tree = ProjectNode.split(
            direction: .horizontal, ratio: 0.5, left: Self.leaf(1),
            right: .stack(shown: 1, members: [Self.leaf(2), Self.leaf(3), Self.leaf(4)]))
        let sizes = ProjectPaneSizes.sizes(of: tree, in: CGSize(width: 1200, height: 656), framed: true)
        var made = 0
        _ = tree.building { _ -> MockView in
            made += 1
            return MockView()
        }
        #expect(sizes.count == made)
        #expect(sizes.allSatisfy { $0 == nil })
    }

    /// Too small to hold a pane is "not known", never a zero the core would
    /// read as one.
    @Test func noRoomIsNotASize() {
        let sizes = ProjectPaneSizes.sizes(of: Self.threePanes, in: CGSize(width: 20, height: 40), framed: true)
        #expect(sizes.allSatisfy { $0 == nil })
    }
}
