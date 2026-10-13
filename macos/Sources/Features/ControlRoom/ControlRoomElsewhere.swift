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
            GeometryReader { place in
                VStack(spacing: CGFloat(Look.Side.rowGap)) {
                    Text(sentence)
                        .foregroundStyle(theme.textSecondary.color)
                    Text(action)
                        .foregroundStyle(theme.attentionText.color)
                }
                .font(.system(size: CGFloat(Look.Font.body)))
                .multilineTextAlignment(.center)
                .background { shade(theme, place: place.size) }
                .padding(CGFloat(Look.Space.frameToContent))
                .frame(width: place.size.width, height: place.size.height)
                .background { ground(theme) }
                // The shade may be larger than the place.
                .clipped()
            }
            // The whole of it takes the press, not only the words.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .backport.pointerStyle(.link)
        .accessibilityLabel(Text(Self.label(sentence: sentence, action: action)))
    }

    /// More of the terminal's ground behind the words, most at the middle
    /// and falling away all the way out with no flat part and no edge:
    /// what keeps them readable over whatever the frame is, so that the
    /// veil over the whole of it can be thin enough for the frame to show
    /// (`shadeSize`, `shadeFall`, `shadeAtMiddle`).
    private func shade(_ theme: Look.Theme, place: CGSize) -> some View {
        GeometryReader { words in
            let size = Self.shadeSize(round: words.size, in: place)
            let middle = Self.shadeAtMiddle(ofWords: words.size, in: place)
            EllipticalGradient(
                stops: Self.shadeFall.map {
                    .init(color: theme.terminalBackground.color.opacity(middle * $0.left), location: CGFloat($0.at))
                },
                center: .center, startRadiusFraction: 0, endRadiusFraction: 0.5)
                .frame(width: size.width, height: size.height)
                .position(x: words.size.width / 2, y: words.size.height / 2)
        }
        .allowsHitTesting(false)
    }

    /// The ellipse the shade fills, round words of `size` in a place of
    /// `place`: half the place's shorter side each way, and more where the
    /// words are long, so that the corners of their box are never far out
    /// in it (`Look.Elsewhere.shadeWordsWithin`). It may be larger than the
    /// place, which cuts it.
    static func shadeSize(round size: CGSize, in place: CGSize) -> CGSize {
        let least = min(place.width, place.height)
        let within = CGFloat(Look.Elsewhere.shadeWordsWithin)
        return CGSize(width: max(least, size.width / within), height: max(least, size.height / within))
    }

    /// How much of the middle's amount is left, by how far out from the
    /// middle (0) to the ellipse's edge (1): a Gaussian, lowered so that
    /// it is nothing at the edge. Close enough together that the straight
    /// lines a gradient draws between them are the curve.
    static let shadeFall: [(left: Double, at: Double)] = {
        let spread = Look.Elsewhere.shadeSpread
        func bell(_ out: Double) -> Double { exp(-(out * out) / (2 * spread * spread)) }
        let edge = bell(1)
        return (0...48).map { step in
            let out = Double(step) / 48
            return (left: (bell(out) - edge) / (1 - edge), at: out)
        }
    }()

    /// `shadeFall` between its points, as a gradient draws it.
    static func shadeLeft(at out: Double) -> Double {
        guard out > 0 else { return 1 }
        for (inner, outer) in zip(shadeFall, shadeFall.dropFirst()) where out <= outer.at {
            return inner.left + (outer.left - inner.left) * (out - inner.at) / (outer.at - inner.at)
        }
        return 0
    }

    /// How far out in the shade the corners of the words' box are: the
    /// point of the words furthest from the middle.
    static func shadeCorner(ofWords size: CGSize, in place: CGSize) -> Double {
        let ellipse = shadeSize(round: size, in: place)
        guard ellipse.width > 0, ellipse.height > 0 else { return 1 }
        let x = Double(size.width / ellipse.width), y = Double(size.height / ellipse.height)
        return (x * x + y * y).squareRoot()
    }

    /// The amount of shade at its middle: whatever leaves
    /// `Look.Elsewhere.shade` at the corners of the words' box.
    static func shadeAtMiddle(ofWords size: CGSize, in place: CGSize) -> Double {
        let left = shadeLeft(at: shadeCorner(ofWords: size, in: place))
        return left > 0 ? min(1, Look.Elsewhere.shade / left) : 1
    }

    /// How much of the terminal's ground is over the frame at the corners
    /// of the words' box, veil and shade together: 1 is none of the frame
    /// showing. Everywhere else under the words there is more.
    static func groundUnderWords(of size: CGSize, in place: CGSize) -> Double {
        let shade = shadeAtMiddle(ofWords: size, in: place) * shadeLeft(at: shadeCorner(ofWords: size, in: place))
        return 1 - (1 - Look.Elsewhere.veil) * (1 - shade)
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
