import SwiftUI

extension ControlRoomLook.RGBA {
    var color: Color {
        Color(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, opacity: a)
    }
}

extension ControlRoomLook {
    /// The theme for the colour scheme a view is drawn in.
    static func theme(_ scheme: ColorScheme) -> Theme {
        theme(dark: scheme == .dark)
    }

    /// A weight from the table's CSS-style number.
    static func weight(_ value: Double) -> SwiftUI.Font.Weight {
        switch value {
        case ..<450: return .regular
        case ..<550: return .medium
        case ..<650: return .semibold
        default: return .bold
        }
    }
}

/// One of the four status glyphs (`control-room.md`, 3.5 items 2 and 3).
///
/// Which one to draw is the core's answer and arrives as `shown`; this only
/// draws it. `.none` draws nothing and still takes the glyph's box, so a row
/// with no glyph lines up with one that has it.
///
/// **Nothing moves under Reduce Motion**: no pulse, no shake, and the
/// spinner stands still. The shapes and the two colours still tell the four
/// apart.
struct ControlRoomGlyph: View {
    typealias Look = ControlRoomLook

    var shown: ControlRoomList.Shown
    /// The longest-waiting one pulses; the rest hold still.
    var pulses: Bool = false
    var size: CGFloat = CGFloat(ControlRoomLook.Side.glyph)
    /// Stops every motion, as Reduce Motion does. For still pictures.
    var still: Bool = false

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shake: CGFloat = 0

    private var moves: Bool { !still && !reduceMotion }

    var body: some View {
        let theme = Look.theme(scheme)
        Group {
            switch shown {
            case .needsYou:
                if pulses && moves {
                    TimelineView(.animation) { context in
                        // Each frame of the breath is one (task 1873).
                        let _ = WindowOpsTally.count(.glyphTicks)
                        symbol(Look.Symbol.waiting, theme.attention)
                            .opacity(Self.pulse(at: context.date.timeIntervalSinceReferenceDate))
                    }
                } else {
                    symbol(Look.Symbol.waiting, theme.attention)
                }
            case .trouble:
                symbol(Look.Symbol.problem, theme.problem)
                    .modifier(Shake(distance: CGFloat(Look.Status.problemShakeDistance) * size / artboard,
                                    progress: shake))
                    .onAppear {
                        guard moves else { return }
                        withAnimation(.linear(duration: Look.Status.problemShakeDuration)) { shake = 1 }
                    }
            case .doneUnseen:
                Circle()
                    .fill(theme.attention.color)
                    .frame(width: CGFloat(Look.Status.doneUnseenDot) * size / artboard,
                           height: CGFloat(Look.Status.doneUnseenDot) * size / artboard)
            case .working:
                if moves {
                    TimelineView(.periodic(from: .distantPast,
                                           by: Look.Status.workingSpinPeriod / Look.Status.workingSpinSteps)) { context in
                        // Each step of the spin is one (task 1873).
                        let _ = WindowOpsTally.count(.glyphTicks)
                        Spinner(step: Self.spinStep(at: context.date.timeIntervalSinceReferenceDate))
                            .foregroundStyle(theme.working.color)
                    }
                } else {
                    Spinner(step: 0).foregroundStyle(theme.working.color)
                }
            case .none:
                Color.clear
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var artboard: CGFloat { CGFloat(Look.Status.artboard) }

    private func symbol(_ name: String, _ color: Look.RGBA) -> some View {
        Image(systemName: name)
            .resizable()
            .scaledToFit()
            .foregroundStyle(color.color)
    }

    /// The pulse's opacity at a time: 1, down to the table's minimum, back.
    static func pulse(at t: TimeInterval) -> Double {
        let phase = t.truncatingRemainder(dividingBy: Look.Status.waitingPulsePeriod) / Look.Status.waitingPulsePeriod
        let dip = (1 - cos(2 * Double.pi * phase)) / 2
        return 1 - (1 - Look.Status.waitingPulseMinOpacity) * dip
    }

    /// Which of the spinner's lines is brightest at a time. It steps.
    static func spinStep(at t: TimeInterval) -> Int {
        let steps = Look.Status.workingSpinSteps
        let phase = t.truncatingRemainder(dividingBy: Look.Status.workingSpinPeriod) / Look.Status.workingSpinPeriod
        return Int(phase * steps) % Int(steps)
    }

    /// Left, right, and back to where it was, once.
    private struct Shake: GeometryEffect {
        var distance: CGFloat
        var progress: CGFloat
        var animatableData: CGFloat {
            get { progress }
            set { progress = newValue }
        }

        func effectValue(size: CGSize) -> ProjectionTransform {
            ProjectionTransform(CGAffineTransform(translationX: distance * sin(progress * 2 * .pi), y: 0))
        }
    }

    /// The progress spinner: short lines round a centre, one bright and the
    /// rest fading behind it.
    private struct Spinner: View {
        var step: Int

        var body: some View {
            Canvas { context, size in
                let unit = size.width / CGFloat(Look.Status.artboard)
                let count = Int(Look.Status.workingSpinSteps)
                let w = CGFloat(Look.Status.workingSpokeWidth) * unit
                let h = CGFloat(Look.Status.workingSpokeLength) * unit
                let inset = CGFloat(Look.Status.workingSpokeInset) * unit
                let faint = Look.Status.workingSpokeMinOpacity
                for n in 0..<count {
                    // 0 is the bright one; the one just ahead of it is faintest.
                    let behind = (step - n + count) % count
                    let ahead = (count - behind) % count
                    let opacity = behind == 0 ? 1 : faint + (1 - faint) * Double(ahead - 1) / Double(count - 1)
                    var spoke = context
                    spoke.translateBy(x: size.width / 2, y: size.height / 2)
                    spoke.rotate(by: .degrees(Double(n) * 360 / Double(count)))
                    spoke.opacity = opacity
                    let rect = CGRect(x: -w / 2, y: -size.height / 2 + inset, width: w, height: h)
                    spoke.fill(Path(roundedRect: rect, cornerRadius: w / 2), with: .foreground)
                }
            }
        }
    }
}
