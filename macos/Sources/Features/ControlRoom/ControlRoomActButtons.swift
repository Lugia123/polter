import AppKit
import SwiftUI

/// The tick and the cross on a row that is waiting for an approval
/// (`control-room.md`, 3.2): approve on the left, refuse on the right.
///
/// **They are the screenshot toolbar's tick and cross**, the same data
/// (`ShotLook.icons`, "done" and "cancel") turned into pixels by the same
/// rule (`ShotIconRaster`), in a button of the toolbar's size -- so the two
/// are one drawing at one size wherever they appear. Only the colour is
/// this list's.
struct ControlRoomActButtons: View {
    typealias Look = ControlRoomLook
    typealias Kind = ControlRoomRowActs.Kind

    /// The ink of a button at rest and under the pointer.
    var tint: Color
    var quiet: Color
    var press: (Kind) -> Void

    var body: some View {
        HStack(spacing: CGFloat(Look.Side.actButtonGap)) {
            button(.approve)
            button(.refuse)
        }
        .fixedSize()
    }

    private func button(_ kind: Kind) -> some View {
        Button { press(kind) } label: {
            ControlRoomActIcon(which: kind)
                .frame(width: CGFloat(Look.Side.actButton), height: CGFloat(Look.Side.actButton))
                .contentShape(Rectangle())
        }
        .buttonStyle(ControlRoomActButtonStyle(tint: tint, quiet: quiet))
        .help(Self.name(kind))
        .accessibilityLabel(Self.name(kind))
    }

    /// What a button is called, for the tooltip and for VoiceOver.
    static func name(_ kind: Kind) -> String {
        switch kind {
        case .approve:
            return String(localized: "Approve", comment: "总控台：行上的勾，批准这一次")
        case .refuse:
            return String(localized: "Refuse", comment: "总控台：行上的叉，拒绝这一次")
        }
    }
}

/// Quiet until pointed at; darker while held.
private struct ControlRoomActButtonStyle: ButtonStyle {
    var tint: Color
    var quiet: Color
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(hovering || configuration.isPressed ? tint : quiet)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .onHover { hovering = $0 }
    }
}

/// One of the two icons, in the current foreground colour.
struct ControlRoomActIcon: View {
    /// Approve or refuse. (Not called `kind`: that is the core's word for
    /// something a host does not read.)
    var which: ControlRoomRowActs.Kind
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        if let image = ControlRoomActGlyph.image(which, scale: Double(displayScale)) {
            Image(decorative: image, scale: displayScale)
                .renderingMode(.template)
        }
    }
}

/// The screenshot toolbar's drawing of a row's button.
enum ControlRoomActGlyph {
    /// The toolbar's icon for `kind`: the data itself, not a copy.
    static func icon(_ kind: ControlRoomRowActs.Kind) -> ShotLook.Icon? {
        ShotLook.icon(kind.toolbarIcon)
    }

    /// Its coverage in a toolbar button at `scale`, by the toolbar's rule.
    static func mask(_ kind: ControlRoomRowActs.Kind, scale: Double) -> ShotIconRaster.Mask? {
        guard let icon = icon(kind) else { return nil }
        return ShotIconRaster.mask(icon, cell: Int((ShotLook.Size.button * scale).rounded()), scale: scale)
    }

    /// The coverage as an image whose alpha is the ink, for a template.
    static func image(_ kind: ControlRoomRowActs.Kind, scale: Double) -> CGImage? {
        guard let mask = mask(kind, scale: scale), mask.cell > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: mask.cell * mask.cell * 4)
        for (i, a) in mask.alpha.enumerated() {
            // White, premultiplied: only the alpha is looked at.
            pixels[i * 4] = a
            pixels[i * 4 + 1] = a
            pixels[i * 4 + 2] = a
            pixels[i * 4 + 3] = a
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: mask.cell, height: mask.cell, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: mask.cell * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
