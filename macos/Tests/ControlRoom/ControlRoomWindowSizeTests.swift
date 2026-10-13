import AppKit
import SwiftUI
import Testing
@testable import Ghostty

/// The control room's window is as small as the window says, whatever is
/// drawn in it (`ControlRoomWindowSize`, task 1502).
///
/// These put real hosting views in real windows that are never shown, and
/// read the least size the window ends up with.
@MainActor struct ControlRoomWindowSizeTests {
    typealias Start = ControlRoomList.SupervisorStart

    /// The window a hosting view is put in, the way AppKit would have it
    /// once it has been laid out: a hosting view that is asked tells its
    /// window its least size a moment after it becomes the content.
    private func settled(_ window: NSWindow) {
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        window.layoutIfNeeded()
    }

    private func window() -> NSWindow {
        NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                 styleMask: [.titled, .resizable], backing: .buffered, defer: true)
    }

    /// The list's column and, beside it, a sentence that may not be
    /// squeezed upright: what the right-hand side had.
    private struct Unsqueezable: View {
        var body: some View {
            HStack(spacing: 0) {
                Color.clear.frame(width: CGFloat(ControlRoomLook.Side.width))
                Text(String(repeating: "every page of its project comes back ", count: 4))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @Test func aHostingViewThatIsAskedLetsASentenceSetTheWindowsLeastHeight() {
        // The defect, as it was: this is what the window did before, and
        // what says the next test's content is one that would do it.
        let window = window()
        window.contentView = NSHostingView(rootView: Unsqueezable())
        settled(window)
        #expect(window.contentMinSize.height > 1000)
    }

    @Test func theWindowsLeastSizeIsItsOwnWhateverIsDrawnInIt() {
        let window = window()
        ControlRoomWindowSize.install(NSHostingView(rootView: Unsqueezable()), in: window)
        settled(window)
        #expect(window.contentMinSize == ControlRoomWindowSize.least)
        // And it can be made that small: nothing in it holds it open.
        window.setContentSize(ControlRoomWindowSize.least)
        settled(window)
        #expect(window.contentView?.frame.size == ControlRoomWindowSize.least)
    }

    @Test func aGroupWithAProjectAndNoSupervisorDoesNotAskForATallWindow() {
        // The right-hand side that did it: the sentence under "Open".
        // Hosted with nothing done to the hosting view, so that what is
        // read is what the side itself asks for: what does not fit scrolls.
        let before = ProjectLink.latest
        defer { ProjectLink.latest = before }
        ProjectLink.latest = ProjectLink.Told(known: true, orders: [], groups: [
            "billing": ProjectLink.GroupProject(tie: "bound", name: "billing", pages: 3, open: false, start: .project, why: ""),
        ])
        let start = Start(state: .absent, canStart: true, failed: .none, role: "polter-supervisor", cwd: "/Users/me/work",
                          last: Start.Last(cli: "claude-code", role: "polter-supervisor", lastCli: "claude-code",
                                           heardMs: 1_700_000_000_000, canResume: false, why: .noSession))
        let side = HStack(spacing: 0) {
            Color.clear.frame(width: CGFloat(ControlRoomLook.Side.width))
            ControlRoomDetailMessage(detail: .noSupervisor(group: "billing"), askFor: {}, start: start)
        }
        // The sentence is there to be the trouble.
        #expect(ProjectLink.startNote(ProjectLink.latest?.groups["billing"]) != nil)
        let window = window()
        window.contentView = NSHostingView(rootView: side)
        settled(window)
        #expect(window.contentMinSize.height < ControlRoomWindowSize.least.height)
    }

    // MARK: Back onto the screen

    /// A 1440x900 screen with a menu bar above and a Dock below.
    private let visible = CGRect(x: 0, y: 70, width: 1440, height: 805)

    @Test func aWindowPushedOffTheBottomIsBroughtBackNoTallerThanItsScreen() {
        // The defect's own numbers: 900 by 1596, its bottom 466 below the
        // screen and its top where the person left it.
        let pushed = CGRect(x: 200, y: -466, width: 900, height: 1596)
        let fits = ControlRoomWindowSize.fitted(pushed, within: visible)
        #expect(fits == CGRect(x: 200, y: 70, width: 900, height: 805))
    }

    @Test func aWindowAlreadyOnItsScreenIsNotTouched() {
        let inside = CGRect(x: 120, y: 150, width: 900, height: 616)
        let fits = ControlRoomWindowSize.fitted(inside, within: visible)
        #expect(fits == inside)
        // Filling it exactly is inside it.
        let filling = ControlRoomWindowSize.fitted(visible, within: visible)
        #expect(filling == visible)
    }

    @Test func aWindowThatFitsButHangsOffAnEdgeIsMovedAndKeepsItsSize() {
        let size = CGSize(width: 900, height: 600)
        let offBottom = ControlRoomWindowSize.fitted(CGRect(origin: CGPoint(x: 100, y: -200), size: size), within: visible)
        #expect(offBottom == CGRect(x: 100, y: 70, width: 900, height: 600))
        let offTop = ControlRoomWindowSize.fitted(CGRect(origin: CGPoint(x: 100, y: 500), size: size), within: visible)
        #expect(offTop == CGRect(x: 100, y: 275, width: 900, height: 600))
        let offRight = ControlRoomWindowSize.fitted(CGRect(origin: CGPoint(x: 1000, y: 150), size: size), within: visible)
        #expect(offRight == CGRect(x: 540, y: 150, width: 900, height: 600))
        let offLeft = ControlRoomWindowSize.fitted(CGRect(origin: CGPoint(x: -300, y: 150), size: size), within: visible)
        #expect(offLeft == CGRect(x: 0, y: 150, width: 900, height: 600))
    }

    @Test func aWindowTooTallOrTooWideIsMadeTheScreensSizeThatWayOnly() {
        let tall = ControlRoomWindowSize.fitted(CGRect(x: 100, y: -500, width: 900, height: 1200), within: visible)
        #expect(tall == CGRect(x: 100, y: 70, width: 900, height: 805))
        let wide = ControlRoomWindowSize.fitted(CGRect(x: -400, y: 150, width: 2000, height: 600), within: visible)
        #expect(wide == CGRect(x: 0, y: 150, width: 1440, height: 600))
    }

    @Test func aWindowLargerThanAScreenThatIsNotAtTheOriginFillsThatScreen() {
        // A second display to the left of the first, lower down.
        let second = CGRect(x: -1920, y: -300, width: 1920, height: 1050)
        let huge = CGRect(x: -2500, y: -900, width: 3000, height: 2400)
        let fits = ControlRoomWindowSize.fitted(huge, within: second)
        #expect(fits == second)
    }
}
