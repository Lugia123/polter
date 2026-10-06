import AppKit

/// What the pointer draws when it is pressed inside the selection.
enum ShotTool: CaseIterable, Equatable {
    case rect, arrow, pen, text, number

    var symbolName: String {
        switch self {
        case .rect: return "rectangle"
        case .arrow: return "arrow.up.right"
        case .pen: return "scribble"
        case .text: return "textformat"
        case .number: return "1.circle"
        }
    }

    var label: String {
        switch self {
        case .rect: return String(localized: "Rectangle", comment: "截图工具栏")
        case .arrow: return String(localized: "Arrow", comment: "截图工具栏")
        case .pen: return String(localized: "Pen", comment: "截图工具栏")
        case .text: return String(localized: "Text", comment: "截图工具栏")
        case .number: return String(localized: "Number", comment: "截图工具栏")
        }
    }
}

extension ShotColor {
    var label: String {
        if self == .red { return String(localized: "Red", comment: "截图工具栏的颜色") }
        if self == .yellow { return String(localized: "Yellow", comment: "截图工具栏的颜色") }
        if self == .blue { return String(localized: "Blue", comment: "截图工具栏的颜色") }
        return String(localized: "White", comment: "截图工具栏的颜色")
    }
}

protocol ShotToolbarDelegate: AnyObject {
    /// A tool was chosen, or -- nil -- the chosen one was pressed again and
    /// the pointer goes back to moving the selection.
    func toolbar(_ toolbar: ShotToolbar, didChoose tool: ShotTool?)
    func toolbar(_ toolbar: ShotToolbar, didChoose color: ShotColor)
    func toolbarDidUndo(_ toolbar: ShotToolbar)
    func toolbarDidCancel(_ toolbar: ShotToolbar)
    func toolbarDidFinish(_ toolbar: ShotToolbar)
}

/// The strip under a selection: five tools, four colours, undo, cancel, done
/// (`dev-docs/poltergeist/screenshot.md`, 3.3).
///
/// Everything sits on one grid -- a button is `cell` square, neighbours are
/// `spacing` apart, groups are `groupSpacing` apart, and the strip keeps
/// `padding` clear all round -- so the icons share a centre line and the
/// swatches line up with them.
final class ShotToolbar: NSView {
    weak var delegate: ShotToolbarDelegate?

    static let cell: CGFloat = 28
    static let spacing: CGFloat = 4
    static let groupSpacing: CGFloat = 12
    static let padding: CGFloat = 6
    static let swatch: CGFloat = 16
    static let cornerRadius: CGFloat = 8

    private var toolButtons: [(tool: ShotTool, button: NSButton)] = []
    private var colorButtons: [(color: ShotColor, button: NSButton)] = []
    private let undoButton: NSButton
    private var tool: ShotTool?
    private var color = ShotColor.palette[0]

    var canUndo: Bool = false {
        didSet { undoButton.isEnabled = canUndo }
    }

    init() {
        undoButton = Self.iconButton("arrow.uturn.backward", label: String(localized: "Undo", comment: "截图工具栏"))
        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.95).cgColor
        layer?.cornerRadius = Self.cornerRadius
        // Dark whatever the system appearance is: it sits on a screenshot,
        // not on a window.
        appearance = NSAppearance(named: .darkAqua)

        var views: [NSView] = []
        for tool in ShotTool.allCases {
            let button = Self.iconButton(tool.symbolName, label: tool.label)
            button.target = self
            button.action = #selector(toolPressed(_:))
            toolButtons.append((tool, button))
            views.append(button)
        }

        for color in ShotColor.palette {
            let button = Self.swatchButton(color)
            button.target = self
            button.action = #selector(colorPressed(_:))
            colorButtons.append((color, button))
            views.append(button)
        }

        undoButton.target = self
        undoButton.action = #selector(undoPressed(_:))
        undoButton.isEnabled = false
        let cancel = Self.iconButton("xmark", label: String(localized: "Cancel", comment: "截图工具栏"))
        cancel.target = self
        cancel.action = #selector(cancelPressed(_:))
        let done = Self.iconButton("checkmark", label: String(localized: "Done", comment: "截图工具栏"))
        done.target = self
        done.action = #selector(donePressed(_:))
        done.contentTintColor = .systemGreen
        views.append(contentsOf: [undoButton, cancel, done])

        for view in views { stack.addArrangedSubview(view) }
        if let lastTool = toolButtons.last?.button { stack.setCustomSpacing(Self.groupSpacing, after: lastTool) }
        if let lastColor = colorButtons.last?.button { stack.setCustomSpacing(Self.groupSpacing, after: lastColor) }

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = Self.spacing
        stack.edgeInsets = NSEdgeInsets(
            top: Self.padding, left: Self.padding, bottom: Self.padding, right: Self.padding)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private let stack = NSStackView()

    override var fittingSize: NSSize { stack.fittingSize }

    // A press on the strip is for the strip, not a new selection under it.
    override func mouseDown(with event: NSEvent) {}

    private static func iconButton(_ symbol: String, label: String) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            ?? NSImage(size: NSSize(width: 16, height: 16))
        let button = NSButton(image: image, target: nil, action: nil)
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        button.contentTintColor = .white
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.wantsLayer = true
        button.layer?.cornerRadius = 5
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: cell),
            button.heightAnchor.constraint(equalToConstant: cell),
        ])
        return button
    }

    private static func swatchButton(_ color: ShotColor) -> NSButton {
        let size = NSSize(width: swatch, height: swatch)
        let image = NSImage(size: size, flipped: false) { rect in
            color.nsColor.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            NSColor(white: 1, alpha: 0.5).setStroke()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).stroke()
            return true
        }
        let button = NSButton(image: image, target: nil, action: nil)
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.toolTip = color.label
        button.setAccessibilityLabel(color.label)
        button.wantsLayer = true
        button.layer?.cornerRadius = 5
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: cell),
            button.heightAnchor.constraint(equalToConstant: cell),
        ])
        return button
    }

    /// Show which tool and which colour are chosen.
    private func refresh() {
        let chosen = NSColor(white: 1, alpha: 0.22).cgColor
        for (tool, button) in toolButtons {
            button.layer?.backgroundColor = tool == self.tool ? chosen : NSColor.clear.cgColor
            button.setAccessibilityValue(tool == self.tool ? "1" : "0")
        }
        for (color, button) in colorButtons {
            button.layer?.backgroundColor = color == self.color ? chosen : NSColor.clear.cgColor
            button.setAccessibilityValue(color == self.color ? "1" : "0")
        }
    }

    @objc private func toolPressed(_ sender: NSButton) {
        guard let pressed = toolButtons.first(where: { $0.button === sender })?.tool else { return }
        // Pressing the chosen tool lets go of it.
        tool = pressed == tool ? nil : pressed
        refresh()
        delegate?.toolbar(self, didChoose: tool)
    }

    @objc private func colorPressed(_ sender: NSButton) {
        guard let pressed = colorButtons.first(where: { $0.button === sender })?.color else { return }
        color = pressed
        refresh()
        delegate?.toolbar(self, didChoose: pressed)
    }

    @objc private func undoPressed(_ sender: NSButton) { delegate?.toolbarDidUndo(self) }
    @objc private func cancelPressed(_ sender: NSButton) { delegate?.toolbarDidCancel(self) }
    @objc private func donePressed(_ sender: NSButton) { delegate?.toolbarDidFinish(self) }
}
