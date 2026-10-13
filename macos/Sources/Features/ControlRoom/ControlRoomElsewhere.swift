import CoreImage
import SwiftUI

/// Where a terminal was, while it is being shown somewhere else: the last
/// frame it drew here, frosted, under the sentence that says where it went.
///
/// A terminal is in one place at a time (`ControlRoomLending`). The place
/// it is not in used to be a flat colour and a line of words with a small
/// link under them; this is both of those places -- the pane in its own tab
/// while the control room has it, and the control room's right-hand side
/// after the person took it back.
///
/// **The frame is a still picture.** It is taken once, as the terminal
/// leaves, and never changes while the terminal goes on drawing elsewhere:
/// a picture that followed it would be a small copy of the terminal that
/// cannot be typed into, which is what this is not. With no frame to show
/// -- the terminal has never been drawn here -- the ground is the flat
/// colour it always was.
///
/// **All of it is one button.** A press anywhere brings the terminal here;
/// the words name what the press does and are not the only place to press.
struct ControlRoomElsewhere: View {
    typealias Look = ControlRoomLook

    /// The last frame the terminal drew here, already frosted
    /// (`frosted`); nil when there is none.
    let frame: CGImage?
    /// Where the terminal is.
    let sentence: String
    /// What pressing does (`switchHere`). It is in the colour a link has,
    /// and is not one: the whole place is the button.
    let action: String
    let perform: () -> Void

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = Look.theme(scheme)
        Button(action: perform) {
            VStack(spacing: CGFloat(Look.Side.rowGap)) {
                Text(sentence)
                    .foregroundStyle(theme.textSecondary.color)
                Text(action)
                    .foregroundStyle(theme.attentionText.color)
            }
            .font(.system(size: CGFloat(Look.Font.body)))
            .multilineTextAlignment(.center)
            .background { shade(theme) }
            .padding(CGFloat(Look.Space.frameToContent))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { ground(theme) }
            // The whole of it takes the press, not only the words.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .backport.pointerStyle(.link)
        .accessibilityLabel(Text(Self.label(sentence: sentence, action: action)))
    }

    /// More of the terminal's ground just behind the words, fading out
    /// round them with no edge: what keeps them readable over whatever the
    /// frame is, so that the veil over the whole of it can be thin enough
    /// for the frame to show (`shadeSize`, `shadeStops`).
    private func shade(_ theme: Look.Theme) -> some View {
        GeometryReader { words in
            let size = Self.shadeSize(round: words.size)
            EllipticalGradient(
                stops: Self.shadeStops.map {
                    .init(color: theme.terminalBackground.color.opacity($0.amount), location: CGFloat($0.at))
                },
                center: .center, startRadiusFraction: 0, endRadiusFraction: 0.5)
                .frame(width: size.width, height: size.height)
                .position(x: words.size.width / 2, y: words.size.height / 2)
        }
        .allowsHitTesting(false)
    }

    /// The ellipse the shade fills, round words of `size`: wide and tall
    /// enough that the corners of the words' box are well inside it.
    static func shadeSize(round size: CGSize) -> CGSize {
        let reach = CGFloat(Look.Elsewhere.shadeReach)
        return CGSize(
            width: size.width * 2.0.squareRoot() + 2 * reach,
            height: size.height * 2.0.squareRoot() + 2 * reach)
    }

    /// How much of the ground the shade lays down, by how far out from
    /// its centre (0) to its edge (1): all of `Look.Elsewhere.shade` out
    /// to `shadeFullWithin`, then eased away to nothing.
    static let shadeStops: [(amount: Double, at: Double)] = {
        let full = Look.Elsewhere.shade
        let within = Look.Elsewhere.shadeFullWithin
        let rest = 1 - within
        return [
            (full, 0), (full, within),
            (full * 0.85, within + rest * 0.25), (full * 0.5, within + rest * 0.5),
            (full * 0.15, within + rest * 0.75), (0, 1),
        ]
    }()

    /// How much of the shade is under the point of the words' box
    /// furthest from its middle -- a corner -- for words of `size`.
    static func shadeAtCorner(ofWords size: CGSize) -> Double {
        let ellipse = shadeSize(round: size)
        guard ellipse.width > 0, ellipse.height > 0 else { return 0 }
        let x = Double(size.width / ellipse.width), y = Double(size.height / ellipse.height)
        let out = (x * x + y * y).squareRoot()
        // Between two stops the amount goes in a straight line.
        for (inner, outer) in zip(shadeStops, shadeStops.dropFirst()) where out <= outer.at {
            guard outer.at > inner.at else { continue }
            return inner.amount + (outer.amount - inner.amount) * (out - inner.at) / (outer.at - inner.at)
        }
        return 0
    }

    /// How much of the terminal's ground is over the frame under the
    /// words, veil and shade together: 1 is none of the frame showing.
    static func groundUnderWords(of size: CGSize) -> Double {
        1 - (1 - Look.Elsewhere.veil) * (1 - shadeAtCorner(ofWords: size))
    }

    /// The second line, wherever the terminal is: pressing brings it here.
    static var switchHere: String {
        String(localized: "Click to switch here", comment: "总控台：终端在别处时那一格上的第二行。整格都能点，点了就把终端切到这里")
    }

    /// One thing to press, called by both of its lines.
    static func label(sentence: String, action: String) -> String {
        "\(sentence) \(action)"
    }

    /// The frame, filling the place whatever shape the place is now --
    /// scaled to cover it and cut at the edges, which nobody can see in a
    /// blurred picture -- under enough of the terminal's ground for the
    /// words to be read over anything.
    @ViewBuilder private func ground(_ theme: Look.Theme) -> some View {
        let colour = theme.terminalBackground.color
        if let frame {
            colour
                .overlay {
                    Image(decorative: frame, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                }
                .clipped()
                .overlay { colour.opacity(Look.Elsewhere.veil) }
        } else {
            colour
        }
    }

    /// The frame to draw under "it is in its own tab": the one taken from
    /// that same terminal as it was given back. Another terminal's frame
    /// is never shown for it; with none taken, and for every other way of
    /// having no terminal (none named, gone, starting), there is none.
    static func frame(for detail: ControlRoomLending.Detail, frozen: (terminal: String, frame: CGImage)?) -> CGImage? {
        guard case let .takenBack(loan) = detail, let frozen, frozen.terminal == loan.terminal else { return nil }
        return frozen.frame
    }

    /// A still, blurred copy of `full`, small (`keptSize`): what is kept
    /// of a terminal's frame as it leaves. Blurred here, once, and not
    /// when it is drawn: the picture never changes afterwards, and the
    /// blur is then the same whatever draws it. Nil for a frame with no
    /// size.
    static func frosted(_ full: CIImage, with context: CIContext) -> CGImage? {
        guard let kept = keptSize(of: full.extent.size) else { return nil }
        let small = full
            .transformed(by: CGAffineTransform(translationX: -full.extent.minX, y: -full.extent.minY))
            .transformed(by: CGAffineTransform(
                scaleX: kept.width / full.extent.width, y: kept.height / full.extent.height))
        // Its edge repeated outwards, so that the blur does not fade the
        // picture's own edges to nothing.
        let blurred = small.clampedToExtent()
            .applyingGaussianBlur(sigma: Look.Elsewhere.blur)
        return context.createCGImage(blurred, from: CGRect(origin: .zero, size: kept))
    }

    /// The size a frame of `pixels` is kept at: no larger than
    /// `Look.Elsewhere.frameLongestSide` on its longer side, never
    /// enlarged, its shape unchanged. Nil for a frame with no size.
    static func keptSize(of pixels: CGSize) -> CGSize? {
        guard pixels.width >= 1, pixels.height >= 1 else { return nil }
        let scale = min(1, CGFloat(Look.Elsewhere.frameLongestSide) / max(pixels.width, pixels.height))
        return CGSize(width: max(1, (pixels.width * scale).rounded()), height: max(1, (pixels.height * scale).rounded()))
    }
}
