import AppKit
import SwiftUI

// MARK: - Menu View

/// The colours a pane can be given, laid flat in a menu: two rows of five,
/// one click (task 1699). It used to set the colour of a whole tab; it
/// sets the colour of one pane now -- the one right-clicked, or on a tab,
/// the pane of that tab that has focus -- and the user asked for it to stay
/// flat rather than go into a submenu, because it is used often.
struct PaneColorMenuView: View {
    @State private var currentSelection: PaneColor
    let onSelect: (PaneColor) -> Void
    @Environment(\.colorScheme) private var scheme

    init(selectedColor: PaneColor, onSelect: @escaping (PaneColor) -> Void) {
        self._currentSelection = State(initialValue: selectedColor)
        self.onSelect = onSelect
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(String(localized: "Color", comment: "分屏右键菜单与标签页右键菜单：给这一格分屏选颜色的那一块的标题"))
                .padding(.bottom, 2)

            ForEach(Self.paletteRows, id: \.self) { row in
                HStack(spacing: 2) {
                    ForEach(row, id: \.self) { color in
                        PaneColorSwatch(
                            color: color,
                            fill: color.dot(ControlRoomLook.theme(scheme))?.color,
                            isSelected: color == currentSelection
                        ) {
                            currentSelection = color
                            onSelect(color)
                        }
                    }
                }
            }
        }
        .padding(.leading, Self.leadingPadding)
        .padding(.trailing, 12)
        .padding(.top, 4)
        .padding(.bottom, 4)
    }

    /// The order of the C enum, which is the order the Windows host's
    /// menu lays them out in too.
    static let paletteRows: [[PaneColor]] = [
        [.none, .blue, .purple, .pink, .red],
        [.orange, .yellow, .green, .teal, .graphite],
    ]

    /// Leading padding to align with the menu's icon gutter.
    /// macOS 26 introduced icons in menus, requiring additional padding.
    private static var leadingPadding: CGFloat {
        if #available(macOS 26.0, *) {
            return 40
        } else {
            return 12
        }
    }
}

/// A single color swatch button in the palette.
private struct PaneColorSwatch: View {
    let color: PaneColor
    /// The look table's dot for the menu's appearance; nil for none.
    let fill: Color?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if let fill {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle.fill")
                        .foregroundStyle(fill)
                } else {
                    Image(systemName: isSelected ? "circle.slash" : "circle")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 16))
            .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
        .help(color.localizedName)
        .accessibilityLabel(color.localizedName)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The palette as a menu item's view. `selectionHandler` is called with the
/// colour picked; it sends the binding to the pane.
func makePaneColorPaletteView(
    selectedColor: PaneColor,
    selectionHandler: @escaping (PaneColor) -> Void
) -> NSView {
    let hostingView = NSHostingView(rootView: PaneColorMenuView(
        selectedColor: selectedColor,
        onSelect: selectionHandler
    ))
    hostingView.frame.size = hostingView.intrinsicContentSize
    return hostingView
}
