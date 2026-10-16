import SwiftUI

extension PolterCloseCircle {
    /// What the text under the button is drawn through: everything but the
    /// column from the band's start to just past the disc
    /// (`PolterCloseCircle.hole`), for a band whose text starts at
    /// `textLeading`. A mask -- that column is a hole in it.
    struct Hole: Shape {
        var textLeading: CGFloat

        func path(in rect: CGRect) -> Path {
            var path = Path(rect)
            let frame = PolterCloseCircle.frame(textLeading: rect.minX + textLeading, height: rect.height)
                .offsetBy(dx: 0, dy: rect.minY)
            path.addRect(PolterCloseCircle.hole(in: rect, button: frame))
            return path
        }
    }
}

extension View {
    /// Cut the close button's disc out of this band while it shows (task
    /// 1642): the band's text starts at `textLeading`.
    func polterCloseHole(_ shows: Bool, textLeading: CGFloat) -> some View {
        mask {
            if shows {
                PolterCloseCircle.Hole(textLeading: textLeading).fill(style: FillStyle(eoFill: true))
            } else {
                Rectangle()
            }
        }
    }
}

/// The button itself. Placed by the caller at
/// `PolterCloseCircle.frame(textLeading:height:)`.
struct PolterCloseCircleButton: View {
    let action: () -> Void

    var body: some View {
        let label = String(localized: "Close Terminal", comment: "分屏标题和层叠标签左端的 x；层叠标签右键菜单：关闭这一个终端")
        Button(action: action) { EmptyView() }
            .buttonStyle(Style())
            .frame(width: PolterCloseCircle.side, height: PolterCloseCircle.side)
            .help(label)
            .accessibilityLabel(label)
    }

    private struct Style: ButtonStyle {
        @Environment(\.colorScheme) private var scheme

        func makeBody(configuration: Configuration) -> some View {
            let dark = scheme == .dark
            let ink: Color = dark ? .white : .black
            let depth = configuration.isPressed ? PolterCloseCircle.discPressed : PolterCloseCircle.discShown
            ZStack {
                Circle()
                    .fill(ink.opacity(dark ? depth.dark : depth.light))
                    .frame(width: PolterCloseCircle.disc, height: PolterCloseCircle.disc)
                Cross()
                    .stroke(ink.opacity(dark ? PolterCloseCircle.crossInk.dark : PolterCloseCircle.crossInk.light),
                            style: StrokeStyle(lineWidth: PolterCloseCircle.stroke, lineCap: .round))
                    .frame(width: PolterCloseCircle.cross, height: PolterCloseCircle.cross)
            }
            .frame(width: PolterCloseCircle.side, height: PolterCloseCircle.side)
            .contentShape(Circle())
        }
    }

    private struct Cross: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            return path
        }
    }
}
