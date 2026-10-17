import AppKit
import SwiftUI

/// What `terminal_highlight` has lit, for the views that draw it (task
/// 1689). Written by `PolterHighlight` and by nothing else; every pane, tab
/// and stack strip reads it and decides for itself whether it is the lit
/// one, one beside it, or neither.
@MainActor
final class PolterHighlightShown: ObservableObject {
    static let shared = PolterHighlightShown()

    /// The lit terminal's id, as the snapshot and `terminal_list` write it.
    @Published private(set) var id: String?
    /// The window it is lit in. Weak: a window that closes ends it anyway.
    private(set) weak var window: NSWindow?
    @Published private(set) var label: String?
    @Published private(set) var title = ""
    @Published private(set) var seconds: Double = 0
    /// When the countdown started; nil while the window is still coming
    /// back from the Dock.
    @Published var started: Date?
    /// Going away at the end of its time.
    @Published private(set) var fading = false

    /// When the breathing started: the curve is a function of time since
    /// then, so the edge, the card and the tab breathe as one.
    private(set) var breathingSince = Date()

    /// The core's id for the terminal in a view, as the snapshot writes it.
    /// Set by `PolterHighlight` before it lights anything; until then it
    /// knows none. A hook rather than a call because the answer needs the
    /// core (`ControlRoomLender.terminal(of:)`), and the views here are
    /// built without it (`tools/mac-logic-tests`).
    static var terminalOf: (NSView) -> String? = { _ in nil }

    func begin(id: String, window: NSWindow, label: String?, title: String, seconds: Double, started: Date?) {
        self.window = window
        self.label = label
        self.title = title
        self.seconds = seconds
        self.started = started
        self.fading = false
        self.breathingSince = Date()
        self.id = id
    }

    func clear(fading: Bool) {
        guard id != nil else { return }
        guard fading else {
            id = nil
            window = nil
            return
        }
        withAnimation(.easeOut(duration: ControlRoomLook.Highlight.fadeOut)) { self.fading = true }
        let gone = id
        DispatchQueue.main.asyncAfter(deadline: .now() + ControlRoomLook.Highlight.fadeOut) { [weak self] in
            guard let self, self.id == gone, self.fading else { return }
            self.id = nil
            self.window = nil
            self.fading = false
        }
    }

    /// What a pane showing terminal `terminal` in `window` draws.
    enum Part: Equatable {
        case none
        /// The lit pane.
        case lit
        /// Another pane of the lit window: dimmed.
        case beside
    }

    func part(terminal: String?, in window: NSWindow?) -> Part {
        // Only in the window it is lit in: a terminal lent to the control
        // room leaves a placeholder at home, and that is not what is lit.
        guard let id, let litWindow = self.window, let window, window === litWindow else { return .none }
        return terminal == id ? .lit : .beside
    }
}

/// The breathing, as an opacity that follows `PolterHighlightRules.breath`.
struct PolterHighlightBreathing<Content: View>: View {
    let since: Date
    let content: (Double) -> Content

    var body: some View {
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if reduce {
            content(PolterHighlightRules.breath(at: 0, reduceMotion: true))
        } else {
            TimelineView(.animation) { context in
                content(PolterHighlightRules.breath(
                    at: context.date.timeIntervalSince(since), reduceMotion: false))
            }
        }
    }
}

/// Over one pane: nothing, the scrim, or the lit pane's edge and card.
struct PolterHighlightPaneOverlay: View {
    /// Whose pane this is: an id, or a view whose id is asked for each time
    /// it draws (`PolterHighlightShown.terminalOf`).
    private let source: Source

    private enum Source {
        case terminal(String?)
        case view(Weak)
    }

    private final class Weak {
        weak var view: NSView?
        init(_ view: NSView) { self.view = view }
    }

    init(terminal: String?) { source = .terminal(terminal) }
    init(of view: NSView) { source = .view(Weak(view)) }

    private var terminal: String? {
        switch source {
        case .terminal(let id): return id
        case .view(let box): return box.view.flatMap(PolterHighlightShown.terminalOf)
        }
    }

    @ObservedObject private var shown = PolterHighlightShown.shared
    @Environment(\.colorScheme) private var scheme
    @State private var window: NSWindow?

    private typealias Look = ControlRoomLook.Highlight

    var body: some View {
        GeometryReader { geometry in
            switch shown.part(terminal: terminal, in: window) {
            case .none:
                Color.clear
            case .beside:
                Rectangle().fill(ControlRoomLook.theme(scheme).highlightScrim.color)
            case .lit:
                lit(size: geometry.size)
            }
        }
        .opacity(shown.fading ? 0 : 1)
        .allowsHitTesting(false)
        .background(PolterHighlightWindowReader(window: $window))
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func lit(size: CGSize) -> some View {
        let style = PolterHighlightRules.style(paneSize: size)
        PolterHighlightBreathing(since: shown.breathingSince) { a in
            ZStack {
                switch style {
                case .card:
                    RoundedRectangle(cornerRadius: Look.edgeRadiusMac)
                        .strokeBorder(Color.accentColor.opacity(a), lineWidth: Look.edge)
                    PolterHighlightCard(shown: shown, breath: a, paneWidth: size.width)
                        .position(x: size.width / 2, y: size.height * Look.cardCenterY)
                case .ring:
                    RoundedRectangle(cornerRadius: Look.edgeRadiusMac)
                        .strokeBorder(Color.accentColor.opacity(a), lineWidth: Look.ringA)
                        .shadow(color: Color.accentColor.opacity(0.7 * a), radius: Look.glowA / 2)
                    PolterHighlightBadge(shown: shown)
                        .padding(6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
            }
        }
    }
}

/// Design B's card: the caller's label, the terminal's title, its id, the
/// countdown, and how to end it.
private struct PolterHighlightCard: View {
    @ObservedObject var shown: PolterHighlightShown
    let breath: Double
    let paneWidth: CGFloat

    @Environment(\.colorScheme) private var scheme
    private typealias Look = ControlRoomLook.Highlight

    var body: some View {
        let theme = ControlRoomLook.theme(scheme)
        VStack(spacing: 0) {
            if let label = shown.label {
                Text(label)
                    .font(.system(size: Look.labelSize, weight: .bold))
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(1)
            }
            Text(shown.title)
                .font(.system(size: Look.titleSize, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.top, shown.label == nil ? 0 : Look.titleGap)
            Text(shown.id ?? "")
                .font(.system(size: ControlRoomLook.Font.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.top, Look.idGap)
            PolterHighlightCountdown(shown: shown)
        }
        .multilineTextAlignment(.center)
        .padding(.top, Look.cardPaddingTop)
        .padding(.horizontal, Look.cardPaddingX)
        .padding(.bottom, Look.cardPaddingBottom)
        .frame(minWidth: min(Look.cardMinWidth, paneWidth * Look.cardMaxWidthFraction))
        .frame(maxWidth: paneWidth * Look.cardMaxWidthFraction)
        .fixedSize(horizontal: true, vertical: true)
        .background(
            RoundedRectangle(cornerRadius: Look.cardRadius).fill(theme.highlightCard.color))
        .overlay(
            RoundedRectangle(cornerRadius: Look.cardRadius)
                .strokeBorder(theme.highlightCardEdge.color, lineWidth: ControlRoomLook.Line.stroke))
        .overlay(
            RoundedRectangle(cornerRadius: Look.cardRadius + Look.cardRing)
                .strokeBorder(Color.accentColor.opacity(Look.cardRingAlpha * breath), lineWidth: Look.cardRing)
                .padding(-Look.cardRing))
        .shadow(color: .black.opacity(0.35), radius: 20, y: 14)
    }
}

/// The bar running down and the line under it, once a second.
private struct PolterHighlightCountdown: View {
    @ObservedObject var shown: PolterHighlightShown
    private typealias Look = ControlRoomLook.Highlight

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            let elapsed = shown.started.map { context.date.timeIntervalSince($0) } ?? 0
            let left = PolterHighlightRules.secondsLeft(total: shown.seconds, elapsed: elapsed)
            VStack(spacing: 0) {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.3))
                        Capsule().fill(Color.accentColor)
                            .frame(width: g.size.width * PolterHighlightRules.barFraction(total: shown.seconds, elapsed: elapsed))
                    }
                }
                .frame(height: Look.barHeight)
                .padding(.top, Look.barGap)
                Text(String(
                    localized: "Press any key or click to end · \(left) s left",
                    comment: "点亮终端时卡片底部的提示；参数是还剩几秒"))
                    .font(.system(size: ControlRoomLook.Font.body))
                    .foregroundStyle(.secondary)
                    .padding(.top, Look.hintGap)
            }
        }
    }
}

/// Design A's badge at the top right of a pane too small for the card.
private struct PolterHighlightBadge: View {
    @ObservedObject var shown: PolterHighlightShown

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            let elapsed = shown.started.map { context.date.timeIntervalSince($0) } ?? 0
            let left = PolterHighlightRules.secondsLeft(total: shown.seconds, elapsed: elapsed)
            HStack(spacing: 6) {
                if let label = shown.label {
                    Text(label).fontWeight(.semibold)
                }
                Text(String(localized: "\(left) s", comment: "点亮终端时小牌子上的剩余秒数"))
            }
            .font(.system(size: ControlRoomLook.Font.body))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .frame(height: 22)
            .background(Capsule().fill(Color.accentColor))
        }
    }
}

/// The window a SwiftUI view is in, which SwiftUI does not say.
struct PolterHighlightWindowReader: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        let view = Reader()
        view.changed = { window = $0 }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Reader: NSView {
        var changed: (NSWindow?) -> Void = { _ in }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let w = window
            DispatchQueue.main.async { [weak self] in
                guard self != nil else { return }
                self?.changed(w)
            }
        }
    }
}

/// The lit terminal's tab in a stack's strip: the dot before its name, and
/// a ground and an edge that breathe with the pane's.
struct PolterHighlightStackTab: View {
    let terminal: String?
    @ObservedObject private var shown = PolterHighlightShown.shared

    var body: some View {
        if let terminal, terminal == shown.id, !shown.fading {
            PolterHighlightBreathing(since: shown.breathingSince) { a in
                RoundedRectangle(cornerRadius: ControlRoomLook.StackTab.cornerRadius)
                    .fill(Color.accentColor.opacity(ControlRoomLook.Highlight.tabGround * a))
                    .overlay(
                        RoundedRectangle(cornerRadius: ControlRoomLook.StackTab.cornerRadius)
                            .strokeBorder(Color.accentColor.opacity(a), lineWidth: ControlRoomLook.Highlight.tabEdge))
            }
            .allowsHitTesting(false)
        }
    }

    /// Whether the dot goes before the name.
    @MainActor
    static func dotShown(for terminal: String?) -> Bool {
        let shown = PolterHighlightShown.shared
        return terminal != nil && terminal == shown.id && !shown.fading
    }
}

/// The accent dot before a lit terminal's name, breathing.
struct PolterHighlightDot: View {
    @ObservedObject private var shown = PolterHighlightShown.shared

    var body: some View {
        PolterHighlightBreathing(since: shown.breathingSince) { a in
            Circle()
                .fill(Color.accentColor.opacity(a))
                .frame(width: ControlRoomLook.Highlight.tabDot, height: ControlRoomLook.Highlight.tabDot)
        }
        .accessibilityHidden(true)
    }
}

/// The highlight laid over a view that is not in a pane of its own -- a
/// terminal lent to the control room. Clicks go through it.
final class PolterHighlightCover: NSHostingView<PolterHighlightPaneOverlay> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
