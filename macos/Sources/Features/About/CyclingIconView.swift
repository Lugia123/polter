import SwiftUI
import GhosttyKit
import Combine

/// The application's icon, in the About window.
///
/// Named for what it used to do: upstream cycles Ghostty's official icon
/// variants here. Polter has one icon, so `AboutViewModel.icons` is empty
/// and this shows the icon the application is actually running under. The
/// cycling is left in place rather than deleted, because a set of Polter
/// variants would only have to be listed to bring it back.
struct CyclingIconView: View {
    @EnvironmentObject var viewModel: AboutViewModel

    var body: some View {
        ZStack {
            iconView(for: viewModel.currentIcon)
                .id(viewModel.currentIcon)
        }
        .animation(.easeInOut(duration: 0.5), value: viewModel.currentIcon)
        .frame(height: 128)
        .onHover { hovering in
            viewModel.isHovering = hovering
        }
        // Both do nothing while there is one icon, and neither is worth
        // showing as a control that does not respond: a tap that never
        // changes anything reads as a bug.
        .onTapGesture {
            guard viewModel.currentIcon != nil else { return }
            viewModel.advanceToNextIcon()
        }
        .contextMenu {
            if let currentIcon = viewModel.currentIcon {
                Button("Copy Icon Config") {
                    NSPasteboard.general.setString("macos-icon = \(currentIcon.rawValue)", forType: .string)
                }
            }
        }
        .accessibilityLabel("Polter Application Icon")
        .accessibilityHint("Click to cycle through icon variants")
    }

    @ViewBuilder
    private func iconView(for icon: Ghostty.MacOSIcon?) -> some View {
        let iconImage: Image = switch icon?.assetName {
        case let assetName?: Image(assetName)
        case nil: ghosttyIconImage()
        }

        iconImage
            .resizable()
            .aspectRatio(contentMode: .fit)
    }
}
