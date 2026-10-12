import AppKit
import SwiftUI
import Testing
@testable import Ghostty

/// A frame goes round a pane without the pane becoming another view
/// (`PaneFrameChrome`, task 1461).
///
/// **What is held to here.** A terminal's view outlives SwiftUI's, and
/// whatever holds it for SwiftUI takes it when it is made. So if putting a
/// frame on, taking it off or changing it ever makes a second holder, the
/// terminal goes to that one -- and when that one is in a split view that
/// is on its way out, the terminal ends in no window. These tests build the
/// split view in small, with a holder that behaves as `SurfaceScrollView`
/// does, and walk it through what a person does to a tab.
///
/// No application is started: the views are in a window that is never put
/// on screen.
@MainActor
struct PaneFrameChromeTests {
    /// Stands for a terminal's own view: made once, never by SwiftUI.
    final class Terminal: NSView {}

    /// Stands for `SurfaceScrollView`: when it is made it takes the
    /// terminal's view for its own, from wherever that was.
    final class Holder: NSView {
        init(_ terminal: NSView) {
            super.init(frame: .zero)
            addSubview(terminal)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }
    }

    final class Count { var made = 0 }

    struct Hold: NSViewRepresentable {
        let terminal: NSView
        let count: Count

        func makeNSView(context: Context) -> Holder {
            count.made += 1
            return Holder(terminal)
        }

        func updateNSView(_ view: Holder, context: Context) {}
    }

    struct Pane: Identifiable {
        let id: Int
        let terminal = Terminal()
        var kind: PaneFrame.Kind = .plain
        /// The terminals the pane holds besides the one it shows, when it
        /// holds a stack: the frame's title is then a strip of tabs.
        var stack: PaneStack?
    }

    /// A stack of three, the second in front.
    static func three(_ kind: PaneFrame.Kind = .worker, current: Int = 1) -> PaneStack {
        PaneStack(members: ["frontend", "api", "e2e"].map { .init(name: $0, shown: .none, wears: kind) }, current: current)
    }

    /// One tab: its panes, which of them is zoomed, and the setting.
    final class Tab: ObservableObject {
        @Published var panes: [Pane] = [Pane(id: 0)]
        @Published var zoomed: Int?
        @Published var enabled = true
        let count = Count()

        var showing: [Pane] { panes.filter { zoomed == nil || $0.id == zoomed } }
        /// Changes whenever the tree changes shape, as the split view's own
        /// identity does: the whole view under it is then made again.
        var shape: String { showing.map { String($0.id) }.joined(separator: ",") }
    }

    struct AloneKey: EnvironmentKey { static let defaultValue = true }
    struct EnabledKey: EnvironmentKey { static let defaultValue = true }

    /// One pane, as `PaneFramed` puts a frame round it: which frame comes
    /// from where the pane is, which arrives through the environment from
    /// outside the view that is rebuilt.
    struct Leaf: View {
        let pane: Pane
        let count: Count
        @Environment(\.paneTestAlone) private var alone
        @Environment(\.paneTestEnabled) private var enabled

        var body: some View {
            let drawn = PaneFrame.drawn(
                terminal: "t\(pane.id)", ownName: "zsh",
                at: .init(enabled: enabled, quickTerminal: false, alone: alone),
                in: [.init(id: "t\(pane.id)", title: "zsh", shown: .none, text: "", pane: pane.kind)])
            Hold(terminal: pane.terminal, count: count)
                .modifier(PaneFrameChrome(
                    wears: drawn?.wears, title: drawn?.title, caption: nil, focused: false,
                    well: .white, cover: .gray, outside: drawn != nil ? 3.5 : 0, stack: pane.stack))
        }
    }

    /// The split view in small: rebuilt whole when its shape changes, and
    /// told from outside that rebuilt part where its panes are.
    struct Root: View {
        @ObservedObject var tab: Tab

        var body: some View {
            HStack(spacing: 1) {
                ForEach(tab.showing) { Leaf(pane: $0, count: tab.count) }
            }
            .id(tab.shape)
            .environment(\.paneTestAlone, tab.showing.count == 1)
            .environment(\.paneTestEnabled, tab.enabled)
            .frame(width: 800, height: 500)
        }
    }

    /// A tab in a window nobody sees, and a way to let SwiftUI catch up.
    final class Stage {
        let tab = Tab()
        let window: NSWindow
        let host: NSHostingView<Root>

        init() {
            host = NSHostingView(rootView: Root(tab: tab))
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.borderless], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            window.contentView = host
            settle()
        }

        func settle() {
            for _ in 0..<4 {
                host.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }
            host.layoutSubtreeIfNeeded()
        }

        func change(_ what: (Tab) -> Void) {
            what(tab)
            settle()
        }

        /// The panes whose terminal is in no window: what a blank pane is.
        var lost: [Int] {
            tab.showing.filter { $0.terminal.window !== window }.map(\.id)
        }
    }

    // MARK: The reported case

    @Test func splittingATabThatHadOneOrdinaryTerminalLeavesBothInTheWindow() {
        let stage = Stage()
        #expect(stage.lost == [])
        // Alone and ordinary: no frame. Split: both are framed, and the
        // view is rebuilt in the same breath.
        stage.change { $0.panes.append(Pane(id: 1)) }
        #expect(stage.lost == [])
        #expect(stage.tab.showing.count == 2)
    }

    @Test func zoomingAPaneOfAFramedTabAndBackLeavesEveryoneInTheWindow() {
        let stage = Stage()
        stage.change { $0.panes += [Pane(id: 1, kind: .worker), Pane(id: 2)] }
        #expect(stage.lost == [])
        // Zoomed, an ordinary terminal is alone: its frame goes.
        stage.change { $0.zoomed = 2 }
        #expect(stage.lost == [])
        stage.change { $0.zoomed = nil }
        #expect(stage.lost == [])
        #expect(stage.tab.showing.count == 3)
    }

    // MARK: Everything a person does to a tab, in a row

    @Test func aTerminalStaysInTheWindowThroughEverythingAPersonDoesToItsTab() {
        let stage = Stage()
        walk(stage)
    }

    /// The same fourteen with the first pane holding a stack from the
    /// start: its title is a strip of tabs through all of it.
    @Test func aTerminalInAStackStaysInTheWindowThroughTheSameFourteenSteps() {
        let stage = Stage()
        stage.change { $0.panes[0].stack = Self.three() }
        #expect(stage.lost == [])
        walk(stage)
        #expect(stage.tab.panes[0].stack != nil)
    }

    /// And with a stack arriving, changing and going in the middle of
    /// them: after every one of the fourteen the pane gains a stack, or
    /// shows another member of it, or loses it.
    @Test func gainingAndLosingAStackBetweenEveryStepLosesNobody() {
        let stage = Stage()
        var turn = 0
        walk(stage) { stage in
            let changes: [(Tab) -> Void] = [
                { $0.panes[0].stack = Self.three() },
                { $0.panes[0].stack?.current = 2 },
                { $0.panes[0].stack = Self.three(.supervisor, current: 0) },
                { $0.panes[0].stack = nil },
            ]
            stage.change(changes[turn % changes.count])
            turn += 1
        }
        #expect(turn == 14)
    }

    /// The fourteen steps, and after each that every terminal showing is
    /// in the window. `between` is run after each step, and the same is
    /// asked again after it.
    private func walk(_ stage: Stage, between: ((Stage) -> Void)? = nil) {
        let first = stage.tab.panes[0].terminal
        let steps: [(String, (Tab) -> Void)] = [
            ("split", { $0.panes.append(Pane(id: 1)) }),
            ("split again", { $0.panes.append(Pane(id: 2)) }),
            ("close one", { $0.panes.removeAll { $0.id == 1 } }),
            ("zoom", { $0.zoomed = 0 }),
            ("unzoom", { $0.zoomed = nil }),
            ("made a worker", { $0.panes[0].kind = .worker }),
            ("zoom a worker", { $0.zoomed = 0 }),
            ("unzoom", { $0.zoomed = nil }),
            ("made a supervisor", { $0.panes[0].kind = .supervisor }),
            ("let go", { $0.panes[0].kind = .plain }),
            ("setting off", { $0.enabled = false }),
            ("setting on", { $0.enabled = true }),
            ("close down to one", { $0.panes.removeAll { $0.id == 2 } }),
            ("split once more", { $0.panes.append(Pane(id: 3)) }),
        ]
        #expect(steps.count == 14)
        for (name, step) in steps {
            stage.change(step)
            #expect(stage.lost == [], "after: \(name)")
            #expect(first.window === stage.window, "after: \(name)")
            if let between {
                between(stage)
                #expect(stage.lost == [], "after what followed: \(name)")
                #expect(first.window === stage.window, "after what followed: \(name)")
            }
        }
    }

    // MARK: The property itself

    @Test func changingWhatAPaneWearsNeverMakesAnotherHolderForItsTerminal() {
        let stage = Stage()
        stage.change { $0.panes.append(Pane(id: 1)) }
        // From here the tree keeps its shape, so nothing may be made again:
        // every change below is only a change of frame.
        let made = stage.tab.count.made
        let holder = stage.tab.panes[0].terminal.superview
        for kind in [PaneFrame.Kind.worker, .supervisor, .plain, .worker, .plain] {
            stage.change { $0.panes[0].kind = kind }
            #expect(stage.tab.count.made == made, "making it \(kind) made a holder")
            #expect(stage.tab.panes[0].terminal.superview === holder, "making it \(kind) moved the terminal")
        }
        // No frame at all, and back.
        stage.change { $0.enabled = false }
        #expect(stage.tab.count.made == made, "taking the frames off made a holder")
        stage.change { $0.enabled = true }
        #expect(stage.tab.count.made == made, "putting the frames back made a holder")
        #expect(stage.tab.panes[0].terminal.superview === holder)
        #expect(stage.lost == [])
    }

    @Test func gainingAStackShowingAnotherMemberAndLosingItNeverMakesAnotherHolder() {
        let stage = Stage()
        stage.change { $0.panes.append(Pane(id: 1)) }
        for kind in [PaneFrame.Kind.plain, .worker, .supervisor] {
            stage.change { $0.panes[0].kind = kind }
            let made = stage.tab.count.made
            let holder = stage.tab.panes[0].terminal.superview
            let size = holder?.frame.size
            let changes: [(String, (Tab) -> Void)] = [
                ("gaining a stack", { $0.panes[0].stack = Self.three(kind) }),
                ("showing another member", { $0.panes[0].stack?.current = 0 }),
                ("the other way of drawing an ordinary one", { $0.panes[0].stack?.plainStyle = .bare }),
                ("losing the stack", { $0.panes[0].stack = nil }),
            ]
            for (name, change) in changes {
                stage.change(change)
                #expect(stage.tab.count.made == made, "\(name) on a \(kind) pane made a holder")
                #expect(stage.tab.panes[0].terminal.superview === holder, "\(name) on a \(kind) pane moved the terminal")
                // The strip is as high as the title it stands for: the
                // terminal is not resized by gaining or losing tabs.
                #expect(stage.tab.panes[0].terminal.superview?.frame.size == size, "\(name) on a \(kind) pane resized the terminal")
            }
        }
        #expect(stage.lost == [])
    }

    @Test func aStripIsAsHighAsTheTitleItStandsFor() {
        #expect(ControlRoomLook.StackTab.stripHeight == ControlRoomLook.Pane.barHeight)
        #expect(ControlRoomLook.StackTab.stripHeight == ControlRoomLook.Pane.plainTitleBandHeight)
    }

    // MARK: With no frame it takes no room

    @Test func aPaneThatWearsNothingIsGivenAllOfItsCell() {
        let stage = Stage()
        // One ordinary terminal: nothing is drawn, nothing is kept clear.
        let alone = stage.tab.panes[0].terminal.superview
        #expect(alone?.frame.size == CGSize(width: 800, height: 500))
        #expect(PaneFrameChrome.room(for: nil) == EdgeInsets())
        // Framed, it gives up its title and the gap round the frame.
        stage.change { $0.panes[0].kind = .worker }
        let framed = stage.tab.panes[0].terminal.superview
        #expect(framed === alone)
        #expect(framed?.frame.size == CGSize(width: 800 - 7, height: 500 - 7 - CGFloat(ControlRoomLook.Pane.barHeight)))
        let supervisor = PaneFrameChrome.room(for: .supervisor)
        #expect(supervisor.top == CGFloat(ControlRoomLook.Pane.barHeight))
        #expect(supervisor.bottom == CGFloat(ControlRoomLook.Space.supervisorBezel))
    }
}

extension EnvironmentValues {
    fileprivate var paneTestAlone: Bool {
        get { self[PaneFrameChromeTests.AloneKey.self] }
        set { self[PaneFrameChromeTests.AloneKey.self] = newValue }
    }

    fileprivate var paneTestEnabled: Bool {
        get { self[PaneFrameChromeTests.EnabledKey.self] }
        set { self[PaneFrameChromeTests.EnabledKey.self] = newValue }
    }
}
