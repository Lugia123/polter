import SwiftUI

extension SplitView {
    /// The split divider that is rendered and can be used to resize a split view.
    ///
    /// It holds values only -- no binding, no closure. A closure in here that
    /// captured the divider, while the divider held the `split` binding, kept
    /// a closed pane alive (#25): the binding's closures hold the split
    /// tree's nodes. So the value it shows comes in as a plain number, and
    /// everything that changes the split (dragging, double-click, VoiceOver's
    /// adjustable action) is attached where `SplitView` creates it (#45).
    ///
    /// `Equatable` is what keeps it that way, not diffing: a `Binding`, a
    /// closure, `@State` or `@Environment` stored here stops the synthesized
    /// conformance from compiling, and the compiler names the property.
    struct Divider: View, Equatable {
        let direction: SplitViewDirection
        let visibleSize: CGFloat
        let invisibleSize: CGFloat
        let color: Color
        /// The current fraction, shown to VoiceOver. Not a binding: see above.
        let split: CGFloat

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
