import SwiftUI

extension SplitView {
    /// The split divider that is rendered and can be used to resize a split view.
    struct Divider: View {
        let direction: SplitViewDirection
        let visibleSize: CGFloat
        let invisibleSize: CGFloat
        let color: Color
        @Binding var split: CGFloat

        private var visibleWidth: CGFloat? {
            switch direction {
            case .horizontal:
                return visibleSize
            case .vertical:
                return nil
            }
        }

        private var visibleHeight: CGFloat? {
            switch direction {
            case .horizontal:
                return nil
            case .vertical:
                return visibleSize
            }
        }

        private var invisibleWidth: CGFloat? {
            switch direction {
            case .horizontal:
                return visibleSize + invisibleSize
            case .vertical:
                return nil
            }
        }

        private var invisibleHeight: CGFloat? {
            switch direction {
            case .horizontal:
                return nil
            case .vertical:
                return visibleSize + invisibleSize
            }
        }

        var body: some View {
            ZStack {
                Color.clear
                    .frame(width: invisibleWidth, height: invisibleHeight)
                    .contentShape(Rectangle()) // Makes it hit testable for pointerStyle
                Rectangle()
                    .fill(color)
                    .frame(width: visibleWidth, height: visibleHeight)
            }
            .modifier(ResizeCursor(direction: direction))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(axLabel)
            .accessibilityValue("\(Int(split * 100))%")
            .accessibilityHint(axHint)
            .accessibilityAddTraits(.isButton)
            .accessibilityAdjustableAction { direction in
                let adjustment: CGFloat = 0.025
                switch direction {
                case .increment:
                    split = min(split + adjustment, 0.9)
                case .decrement:
                    split = max(split - adjustment, 0.1)
                @unknown default:
                    break
                }
            }
        }

        private var axLabel: String {
            switch direction {
            case .horizontal:
                return "Horizontal split divider"
            case .vertical:
                return "Vertical split divider"
            }
        }

        private var axHint: String {
            switch direction {
            case .horizontal:
                return "Drag to resize the left and right panes"
            case .vertical:
                return "Drag to resize the top and bottom panes"
            }
        }
    }

    /// The divider's resize cursor.
    ///
    /// It is a type of its own, holding nothing but `direction`, so that its
    /// `onHover` closure cannot capture the `Divider`. One that did kept a
    /// closed pane alive -- its view, its shell and its pty -- until the next
    /// mouse event in the window's content, however long that took (#25). The
    /// `Divider` holds the `split` binding, and the binding's closures hold the
    /// split tree's nodes. (Measured: capturing the `Divider` is what made the
    /// pane stay. Read from code, not measured: that the path runs through the
    /// binding.) Anything the cursor needs goes in here as a value.
    fileprivate struct ResizeCursor: ViewModifier {
        let direction: SplitViewDirection

        private var pointerStyle: BackportPointerStyle {
            return switch direction {
            case .horizontal: .resizeLeftRight
            case .vertical: .resizeUpDown
            }
        }

        func body(content: Content) -> some View {
            content
                .backport.pointerStyle(pointerStyle)
                .onHover { isHovered in
                    // macOS 15+ we use the pointerStyle helper which is much less
                    // error-prone versus manual NSCursor push/pop
                    if #available(macOS 15, *) {
                        return
                    }

                    if isHovered {
                        switch direction {
                        case .horizontal:
                            NSCursor.resizeLeftRight.push()
                        case .vertical:
                            NSCursor.resizeUpDown.push()
                        }
                    } else {
                        NSCursor.pop()
                    }
                }
        }
    }
}
