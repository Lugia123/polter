import AppKit

/// A line of words that appears for a moment and goes by itself: what Save
/// says when it is done. A panel that takes no focus and no clicks, so that
/// it is nowhere in the way of whatever the person goes on to do, and no
/// notification permission to ask for.
enum ShotToast {
    private static var panel: NSPanel?
    private static var gone: DispatchWorkItem?

    /// How long it stays, in seconds.
    static let stays: TimeInterval = 2.4

    /// From any thread; it is put up on the main one.
    static func show(_ text: String) {
        DispatchQueue.main.async { present(text) }
    }

    private static func present(_ text: String) {
        panel?.orderOut(nil)
        gone?.cancel()

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: NSFont.systemFontSize(for: .regular))
        label.textColor = .white
        label.lineBreakMode = .byTruncatingMiddle
        label.sizeToFit()
        let pad = NSSize(width: 18, height: 10)
        let size = NSSize(
            width: min(label.frame.width, 720) + pad.width * 2, height: label.frame.height + pad.height * 2)

        let blur = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        blur.material = .hudWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = size.height / 2
        blur.layer?.masksToBounds = true
        label.frame = NSRect(
            x: pad.width, y: pad.height, width: size.width - pad.width * 2, height: label.frame.height)
        blur.addSubview(label)

        let screen = NSScreen.main ?? NSScreen.screens.first
        let frame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        let panel = NSPanel(
            contentRect: NSRect(
                x: frame.midX - size.width / 2, y: frame.minY + 80, width: size.width, height: size.height),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = blur
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.orderFrontRegardless()
        Self.panel = panel

        let work = DispatchWorkItem {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.25
                panel.animator().alphaValue = 0
            }, completionHandler: {
                panel.orderOut(nil)
                if Self.panel === panel { Self.panel = nil }
            })
        }
        gone = work
        DispatchQueue.main.asyncAfter(deadline: .now() + stays, execute: work)
    }
}
