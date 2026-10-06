import AppKit
import OSLog

/// The words the overlay shows, in the app's language. The keys are the
/// English msgids `src/input/screenshot.zig` names, so that both hosts say
/// the same thing.
enum ShotWords {
    static func translate(_ msgid: String) -> String {
        Bundle.main.localizedString(forKey: msgid, value: msgid, table: nil)
    }
}

protocol ShotSessionDelegate: AnyObject {
    /// Cancelled: nothing was written and the clipboard is as it was.
    func sessionDidCancel(_ session: ShotSession)
    func sessionDidFinish(_ session: ShotSession, with result: ShotSession.Result)
}

/// One screenshot from the frozen screen to the composed image: the
/// overlays, the editor that decides what every click and key does, and the
/// two things the editor cannot own -- the text box and the frames of a long
/// screenshot (`dev-docs/poltergeist/screenshot.md`, 3.2 and section 9).
///
/// Everything here runs on the main thread.
final class ShotSession {
    /// What a finished screenshot is.
    struct Result {
        /// The picture, with everything that must not leave already gone
        /// from it.
        var image: ComposedImage
        /// The annotations in the image's own pixels, for the sidecar and
        /// the pasted line. Empty for a long screenshot.
        var items: [Annotation]
        var isLong: Bool
        var scale: Double
        /// The display it was taken on: its index, and its size in pixels.
        var display: Int
        var displaySize: Annotation.PixelSize
        /// The selection in that display's own pixels.
        var selection: PixelRect
        /// The window the selection is, when it still is exactly that
        /// window, and that window's bounds in the display's own pixels.
        var window: ShotWindow?
        var windowRect: PixelRect?
    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "polter",
        category: String(describing: ShotSession.self)
    )

    /// How often a long screenshot takes a frame.
    static let longInterval: TimeInterval = 0.12
    /// How much of the picture outside the focus is left: about 57%.
    private static let dim: CGFloat = 0.43

    weak var delegate: ShotSessionDelegate?

    private let displays: [ShotDisplay]
    private let space: ShotScreenSpace
    private let frozen: [FrozenImage]
    private let windows: [UInt64: ShotWindow]
    private(set) var editor: ShotEditor
    private let measure = ShotTextMeasure()
    private var overlays: [(window: ShotOverlayWindow, view: ShotOverlayView)] = []

    /// The text box, while one is open.
    private var textView: ShotTextView?
    var isTyping: Bool { textView != nil }

    /// A long screenshot being taken.
    private struct Long {
        var stitcher: ShotStitcher
        var capture: ShotLiveCapture
        var timer: Timer
        /// What the last frame that said something was.
        var last: ShotStitcher.Step = .unchanged
        var frames = 0
        var lost = 0
        /// Frames held back because the screen was still changing.
        var moving = 0
    }
    private var long: Long?

    /// The mosaics as they were last painted, so that a repaint which did
    /// not change them does not compute them again.
    private struct MosaicPatch {
        var items: [Annotation]
        var display: Int
        var rect: PixelRect
        var image: CGImage
    }
    private var mosaicCache: MosaicPatch?

    /// Nil when a display's picture could not be read.
    init?(displays: [ShotDisplay], windows: [ShotWindow], prefs: ToolPrefs, preselect: CGPoint?) {
        let space = ShotScreenSpace(displays.map {
            .init(frame: $0.frame, pixels: .init($0.image.width, $0.image.height))
        })
        var frozen: [FrozenImage] = []
        for (i, display) in displays.enumerated() {
            guard let bytes = ShotRenderer.rgbx(of: display.image),
                  let picture = FrozenImage(rect: space.displays[i].rect, rgbx: bytes) else { return nil }
            frozen.append(picture)
        }
        self.displays = displays
        self.space = space
        self.frozen = frozen
        self.windows = Dictionary(windows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.editor = ShotEditor(
            displays: space.displays,
            windows: space.windows(windows.map { .init(id: $0.id, frame: $0.frame) }),
            prefs: prefs,
            preselect: preselect.flatMap(space.pixel(ofGlobal:)))
    }

    // MARK: Showing and closing

    func show() {
        for (i, display) in displays.enumerated() {
            let view = ShotOverlayView(index: i, size: display.screen.frame.size)
            view.session = self
            let window = ShotOverlayWindow(display: display)
            window.contentView = view
            overlays.append((window, view))
        }
        // The overlay under the pointer takes the keyboard.
        let mouse = NSEvent.mouseLocation
        let under = overlays.first(where: { $0.window.frame.contains(mouse) }) ?? overlays.first
        for overlay in overlays { overlay.window.orderFrontRegardless() }
        under?.window.makeKey()
        under?.window.makeFirstResponder(under?.view)
    }

    /// Take everything down. The frozen pictures go with this object.
    private func close() {
        long?.timer.invalidate()
        long = nil
        if let textView {
            self.textView = nil
            textView.onCommit = nil
            textView.removeFromSuperview()
        }
        for overlay in overlays {
            overlay.view.session = nil
            overlay.window.orderOut(nil)
            overlay.window.contentView = nil
        }
        overlays = []
    }

    /// The tool memory as it is now, to be saved for the next screenshot.
    var prefs: ToolPrefs { editor.prefs }

    private func repaint() {
        for overlay in overlays { overlay.view.needsDisplay = true }
    }

    // MARK: From the views

    func pointerDown(at local: CGPoint, on index: Int, mods: ShotMods, double: Bool) {
        guard overlays.indices.contains(index) else { return }
        let window = overlays[index].window
        if !window.isKeyWindow, textView == nil {
            window.makeKey()
            window.makeFirstResponder(overlays[index].view)
        }
        let p = space.pixel(ofLocal: local, on: index)
        let effect = double
            ? editor.doubleClick(at: p, mods: mods, measure: measure)
            : editor.pointerDown(at: p, mods: mods, measure: measure)
        perform(effect)
    }

    func pointerMove(to local: CGPoint, on index: Int, mods: ShotMods) {
        let p = space.pixel(ofLocal: local, on: index)
        perform(editor.pointerMove(to: p, mods: mods))
        cursor(at: local, on: index).set()
    }

    func pointerUp(at local: CGPoint, on index: Int) {
        perform(editor.pointerUp(at: space.pixel(ofLocal: local, on: index)))
    }

    func rightClick(on index: Int) {
        perform(editor.rightClick())
    }

    func key(_ event: NSEvent, on index: Int) {
        let input = EditorKey.Input.of(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers)
        let mods = ShotMods(event.modifierFlags.intersection(.deviceIndependentFlagsMask))
        let before = editor.items.count
        let (key, effect) = editor.key(input, mods: mods, measure: measure)
        Self.logger.debug("screenshot: key \(event.keyCode, privacy: .public) mods=\(mods.rawValue, privacy: .public) annotations=\(before, privacy: .public) -> \(String(describing: key), privacy: .public)")
        perform(effect)
    }

    /// An arrow over the toolbar, a crosshair everywhere else.
    func cursor(at local: CGPoint, on index: Int) -> NSCursor {
        let p = space.pixel(ofLocal: local, on: index)
        return editor.layout?.covers(p) == true ? .arrow : .crosshair
    }

    /// Do what the editor asked for.
    private func perform(_ effect: ShotEditor.Effect) {
        switch effect {
        case .none:
            break
        case .repaint, .capture, .release:
            // AppKit keeps sending a drag to the view it started in, so
            // there is no capture to take or give back.
            repaint()
        case .cancel:
            cancel()
        case .finish:
            finish()
        case .long:
            startLong()
        case .leaveLong:
            stopLong()
        case .openText:
            openText()
        case .restyleText:
            restyleText()
        case .commitText:
            commitText()
        }
    }

    private func cancel() {
        close()
        delegate?.sessionDidCancel(self)
    }

    // MARK: The text box

    private static func paper(for colour: Int) -> NSColor {
        // Dark paper under light ink, light under dark.
        let c = ShotStyle.colour(colour)
        let luma = (299 * Int(c.r) + 587 * Int(c.g) + 114 * Int(c.b)) / 1000
        return luma > 150 ? NSColor(white: 0.19, alpha: 1) : .white
    }

    private func style(_ view: ShotTextView, as box: ShotEditor.TextBox, scale: Double) {
        let fontPx = ShotStyle.fontPx(level: box.level, scale: scale)
        let font = ShotFont.font(size: CGFloat(fontPx) / CGFloat(scale)) as NSFont
        let ink = NSColor(cgColor: ShotRenderer.colour(ShotStyle.colour(box.colour))) ?? .red
        view.font = font
        view.textColor = ink
        view.insertionPointColor = ink
        view.backgroundColor = Self.paper(for: box.colour)
        view.typingAttributes = [.font: font, .foregroundColor: ink]
    }

    /// Open a text view for the text the editor is about to take.
    private func openText() {
        guard let box = editor.textBox, let selection = editor.selection,
              overlays.indices.contains(selection.display) else {
            // The editor has a box the host cannot show: end it, empty.
            perform(editor.endText("", measure: measure))
            return
        }
        let index = selection.display
        let scale = editor.scale
        let display = space.displays[index].rect
        let fontPx = ShotStyle.fontPx(level: box.level, scale: scale)
        let pad = ShotStyle.px(4, scale: scale)
        let width = max(
            min(max(selection.rect.right - box.at.x, ShotStyle.px(200, scale: scale)), display.right - box.at.x),
            ShotStyle.px(40, scale: scale))
        let height = min(fontPx * 4, max(display.bottom - box.at.y, fontPx + pad * 2))
        let frame = space.local(PixelRect(box.at.x, box.at.y, width, height), on: index)

        let view = ShotTextView(frame: frame)
        view.isRichText = false
        view.allowsUndo = true
        view.drawsBackground = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.focusRingType = .none
        style(view, as: box, scale: scale)
        view.string = box.text
        // The caret after what is already there.
        view.setSelectedRange(NSRange(location: (box.text as NSString).length, length: 0))
        view.onCommit = { [weak self] in self?.commitText() }
        view.staysOpen = { [weak self] in self?.pressRestylesText() ?? false }

        textView = view
        let overlay = overlays[index]
        overlay.view.addSubview(view)
        overlay.window.makeKey()
        overlay.window.makeFirstResponder(view)
        repaint()
    }

    /// Whether the event being delivered is a press the editor answers by
    /// changing the text being typed (a colour, a size).
    ///
    /// AppKit makes the view that was clicked the first responder *before*
    /// it sends it the press, so the text view is asked to give up the
    /// keyboard first. Ending the text there meant the press found no box:
    /// the piece kept its old colour and only the tool's memory changed
    /// (task 1098). `restyleText` gives the keyboard back.
    private func pressRestylesText() -> Bool {
        guard let event = NSApp.currentEvent, event.type == .leftMouseDown,
              let index = overlays.firstIndex(where: { $0.window === event.window }) else { return false }
        let local = overlays[index].view.convert(event.locationInWindow, from: nil)
        return editor.restylesText(at: space.pixel(ofLocal: local, on: index))
    }

    /// The text's colour or size changed while it is being typed: the box
    /// follows, so that what is seen while typing is what will be drawn.
    private func restyleText() {
        guard let textView, let box = editor.textBox else { return }
        style(textView, as: box, scale: editor.scale)
        if let storage = textView.textStorage {
            storage.setAttributes(textView.typingAttributes, range: NSRange(location: 0, length: storage.length))
        }
        textView.window?.makeFirstResponder(textView)
        repaint()
    }

    /// Close the text box and hand what was typed to the editor, which
    /// decides what it becomes (nothing, if nothing was typed).
    ///
    /// **Called again from inside itself**: taking the view away makes it
    /// give up the keyboard, and giving up the keyboard commits. So the view
    /// is taken out of `textView` and the text is given to the editor
    /// *before* the view is touched. The second call then finds no view and
    /// an editor with no box, and `endText` with no box does nothing --
    /// rather than ending the text with an empty string, which is how the
    /// other host once lost everything typed.
    private func commitText() {
        guard let view = textView else {
            // No view. If the editor still has a box, it is one that failed
            // to open; with none this is the second call, and nothing.
            if editor.textBox != nil { perform(editor.endText("", measure: measure)) }
            return
        }
        textView = nil
        view.onCommit = nil
        view.staysOpen = nil
        let effect = editor.endText(view.string, measure: measure)
        let window = view.window
        let owner = view.superview
        view.removeFromSuperview()
        if let window, let owner { window.makeFirstResponder(owner) }
        perform(effect)
        repaint()
    }

    // MARK: Long screenshots

    /// Enter long-screenshot mode (the editor already has): open the
    /// selection to the live screen and start taking frames.
    ///
    /// The overlay is drawn with a hole where the selection is. What is
    /// under the hole shows -- the live page -- and the mouse over the hole
    /// is not this window's at all, so the wheel scrolls the application
    /// underneath with nothing forwarded and nothing to get wrong. The
    /// frames are taken with the overlays left out, so a toolbar that had
    /// to sit inside a selection as tall as the display is not in them.
    private func startLong() {
        guard let selection = editor.selection, displays.indices.contains(selection.display),
              let stitcher = ShotStitcher(width: selection.rect.w, height: selection.rect.h),
              let displayID = ShotCapture.displayID(of: displays[selection.display].screen) else {
            Self.logger.error("screenshot: a long screenshot could not be started")
            return
        }
        let capture = ShotLiveCapture(
            displayID: displayID,
            region: space.local(selection.rect, on: selection.display),
            pixels: .init(selection.rect.w, selection.rect.h),
            overlayNumbers: overlays.map(\.window.windowNumber))
        let timer = Timer(timeInterval: Self.longInterval, repeats: true) { [weak self] _ in self?.longTick() }
        RunLoop.main.add(timer, forMode: .common)
        long = Long(stitcher: stitcher, capture: capture, timer: timer)
        Self.logger.info("screenshot: long screenshot started, frames of \(selection.rect.w, privacy: .public)x\(selection.rect.h, privacy: .public) every \(Int(Self.longInterval * 1000), privacy: .public) ms")
        repaint()
    }

    /// Leave long-screenshot mode without finishing: cover the selection
    /// again.
    private func stopLong() {
        guard let long else { return }
        long.timer.invalidate()
        self.long = nil
        Self.logger.info("screenshot: long screenshot left without finishing: \(long.frames, privacy: .public) frame(s), \(long.lost, privacy: .public) dropped, \(long.stitcher.totalHeight, privacy: .public) px discarded")
        repaint()
    }

    /// Take one frame of the selection as it is on the live screen and hand
    /// it to the stitcher.
    private func longTick() {
        guard let capture = long?.capture else { return }
        capture.frame { [weak self] frame in
            guard let self, let frame, var long = self.long else { return }
            // Only a frame seen twice running is joined: one caught half
            // painted is `.moving` and waits for the next.
            let step = long.stitcher.offer(frame)
            long.frames += 1
            if step == .lost { long.lost += 1 }
            if step == .moving { long.moving += 1 }
            // What the hint shows follows the last frame that said
            // something: a frame that is unchanged, or still moving, does
            // not clear "scroll slower".
            let shown = step == .unchanged || step == .moving ? long.last : step
            var changed = shown != long.last
            if case .added = step { changed = true }
            // The status line also changes on the frame that makes it say
            // the region keeps changing.
            if step == .moving, long.moving == ShotStitcher.restlessAfter, long.stitcher.isRestless(held: long.moving) {
                changed = true
            }
            if step == .full && long.last != .full {
                Self.logger.info("screenshot: long screenshot reached the \(ShotStitcher.maxHeight, privacy: .public) px limit; no more is added")
                long.timer.invalidate()
            }
            long.last = shown
            self.long = long
            if changed { self.repaint() }
        }
    }

    // MARK: Finishing

    /// Done: compose the image and hand it over.
    private func finish() {
        commitText()
        guard let export = editor.export(), frozen.indices.contains(export.selection.display) else { return }
        let taken = long
        long?.timer.invalidate()
        long = nil
        if let taken {
            Self.logger.info("screenshot: long screenshot finished: \(taken.frames, privacy: .public) frame(s), \(taken.lost, privacy: .public) dropped for want of overlap, \(taken.moving, privacy: .public) held back (still moving), \(taken.stitcher.totalHeight, privacy: .public) px tall")
            if taken.stitcher.neverSteady {
                Self.logger.info("screenshot: long screenshot: the region never held still for two frames in a row, so nothing was joined; the picture is the first frame taken, \(taken.stitcher.height, privacy: .public) px tall")
            }
        }
        close()

        let index = export.selection.display
        let image: ComposedImage?
        if let taken {
            // Stitched frames carry no annotations and need no composing.
            image = taken.stitcher.finish().flatMap { ComposedImage(width: $0.width, rgbx: $0.rgbx) }
        } else {
            image = ShotRenderer.compose(
                frozen: frozen[index], selection: export.selection.rect, items: export.onScreen, scale: export.scale)
        }
        guard let image else {
            Self.logger.error("screenshot: the selection could not be composed; nothing written")
            delegate?.sessionDidCancel(self)
            return
        }

        let window = export.selection.window.flatMap { windows[$0] }
        let display = space.displays[index].rect
        delegate?.sessionDidFinish(self, with: Result(
            image: image,
            items: taken == nil ? export.onImage : [],
            isLong: taken != nil,
            scale: export.scale,
            display: index,
            displaySize: .init(display.w, display.h),
            selection: space.displayLocal(export.selection.rect, on: index),
            window: window,
            // The window's own bounds, not the part of it on the screen:
            // that part is `selection`. An agent's capture of the same
            // window records the same rectangle (11).
            windowRect: window
                .flatMap { space.wholePixels(ofGlobal: $0.frame, on: index) }
                .map { space.displayLocal($0, on: index) }))
    }

    // MARK: Drawing

    /// The mosaics on display `index` as a patch of picture, computed from
    /// the frozen original -- including the one being dragged out, so its
    /// size is chosen by what it hides.
    private func mosaics(on index: Int, scale: Double) -> (rect: PixelRect, image: CGImage)? {
        func isMosaic(_ item: Annotation) -> Bool {
            if case .mosaic = item.shape { return true }
            return false
        }
        let items = (editor.items + (editor.live.map { [$0] } ?? [])).filter(isMosaic)
        guard !items.isEmpty else {
            mosaicCache = nil
            return nil
        }
        if let cache = mosaicCache, cache.items == items, cache.display == index { return (cache.rect, cache.image) }

        let display = space.displays[index].rect
        var union: PixelRect?
        for item in items {
            guard let part = item.bounds(scale: scale).intersect(display) else { continue }
            union = union.map {
                PixelRect(
                    left: min($0.x, part.x), top: min($0.y, part.y),
                    right: max($0.right, part.right), bottom: max($0.bottom, part.bottom))
            } ?? part
        }
        guard let rect = union,
              let composed = ComposedImage(
                frozen: frozen[index], selection: rect, items: items, scale: scale, redact: []),
              let image = composed.cgImage() else { return nil }
        mosaicCache = MosaicPatch(items: items, display: index, rect: composed.rect, image: image)
        return (composed.rect, image)
    }

    /// Paint display `index`. `ctx` is the view's: points, from the top
    /// left.
    func draw(display index: Int, in ctx: CGContext) {
        guard displays.indices.contains(index) else { return }
        let display = space.displays[index]
        let whole = display.rect
        let scale = display.scale
        func cg(_ r: PixelRect) -> CGRect { CGRect(x: r.x, y: r.y, width: r.w, height: r.h) }

        ctx.saveGState()
        defer { ctx.restoreGState() }
        // From here one unit is one pixel, in the editor's coordinates.
        ctx.scaleBy(x: 1 / CGFloat(scale), y: 1 / CGFloat(scale))
        ctx.translateBy(x: -CGFloat(whole.x), y: -CGFloat(whole.y))

        // What is in focus on this display: the selection, the region being
        // dragged, or the window under the pointer. The rest dims.
        let selection = editor.selection.flatMap { $0.display == index ? $0.rect : nil }
        let forming = editor.forming.flatMap { $0.display == index ? $0.rect : nil }
        let hover = editor.selection == nil && editor.forming == nil
            ? editor.hover.flatMap { $0.display == index ? $0.rect : nil } : nil
        let focus = selection ?? forming ?? hover
        let hole = long != nil ? selection : nil

        // The frozen picture, with the mosaics in it.
        ShotRenderer.draw(displays[index].image, in: cg(whole), of: ctx)
        if selection != nil, let patch = mosaics(on: index, scale: scale) {
            ShotRenderer.draw(patch.image, in: cg(patch.rect), of: ctx)
        }

        ctx.saveGState()
        ctx.addRect(cg(whole))
        if let focus { ctx.addRect(cg(focus)) }
        ctx.setFillColor(CGColor(gray: 0, alpha: Self.dim))
        ctx.fillPath(using: .evenOdd)
        ctx.restoreGState()

        if selection != nil {
            func isMosaic(_ item: Annotation) -> Bool {
                if case .mosaic = item.shape { return true }
                return false
            }
            var drawn = editor.drawOrder.filter { !isMosaic($0.item) }
            if let live = editor.live, !isMosaic(live) { drawn.append((index: Int.max, item: live)) }
            ShotRenderer.draw(
                drawn, in: ctx, scale: scale, hideTextOf: editor.textBox?.editing,
                highlighter: ShotRenderer.blendedHighlighter(in: ctx))
        }

        // A long screenshot: the selection is the live screen.
        if let hole {
            ctx.saveGState()
            ctx.setBlendMode(.clear)
            ctx.fill(cg(hole))
            ctx.restoreGState()
        }

        let accent = ShotRenderer.colour(ShotRenderer.accent)
        if let focus {
            ShotRenderer.frame(focus, accent, thickness: ShotStyle.px(2, scale: scale), in: ctx)
        }
        guard let selection else { return }

        let knob = ShotStyle.px(4, scale: scale)
        func drawKnob(_ c: PixelPoint) {
            ShotRenderer.fill(PixelRect(c.x - knob, c.y - knob, knob * 2, knob * 2), accent, in: ctx)
        }
        if long == nil {
            if let i = editor.selected, editor.items.indices.contains(i) {
                // The selected annotation: its grips, or its outline when
                // it can only be moved.
                let item = editor.items[i]
                let grips = item.grips
                if grips.isEmpty {
                    ShotRenderer.frame(item.bounds(scale: scale), accent, thickness: 1, in: ctx)
                }
                for grip in grips { drawKnob(grip.at) }
            } else if editor.tool == .select {
                // Otherwise the selection's own handles, while the select
                // tool is what the mouse is.
                for handle in PixelHandle.all { drawKnob(handle.at(selection)) }
            }
        }

        // The selection's size, in pixels of the image.
        let labelHeight = ShotStyle.px(22, scale: scale)
        let labelY = selection.y - whole.y >= labelHeight
            ? selection.y - labelHeight : selection.y + ShotStyle.px(4, scale: scale)
        ShotRenderer.label(
            "\(selection.w) × \(selection.h)", at: PixelPoint(selection.x, labelY),
            within: whole, scale: scale, in: ctx)

        guard let layout = editor.layout else { return }
        let below = ShotRenderer.drawToolbar(
            layout, editor: editor, scale: scale, display: whole, in: ctx, translate: ShotWords.translate)
        if let long {
            drawLongStatus(long, at: PixelPoint(layout.bar.x, below), selection: selection, display: whole, scale: scale, in: ctx)
        }
    }

    /// Under the toolbar: how tall the picture is so far and what the last
    /// frame meant; and beside the selection, a small copy of the picture.
    private func drawLongStatus(
        _ long: Long, at: PixelPoint, selection: PixelRect, display: PixelRect, scale: Double, in ctx: CGContext
    ) {
        var text = "\(ShotWords.translate("Long Screenshot")) \(long.stitcher.totalHeight) px"
        switch long.last {
        case _ where long.stitcher.isRestless(held: long.moving):
            text += " — " + ShotWords.translate("The picture keeps changing, so nothing can be added.")
        case .lost: text += " — " + ShotWords.translate("Scroll slower")
        case .full: text += " — " + ShotWords.translate("The height limit was reached.")
        default:
            if long.stitcher.totalHeight <= selection.h {
                text += " — " + ShotWords.translate("Scroll down slowly. What comes into view is added at the bottom.")
            }
        }
        ShotRenderer.label(text, at: at, within: display, scale: scale, in: ctx)

        // The preview: right of the selection, or left of it, or not at all.
        let gap = ShotStyle.px(12, scale: scale)
        let width = ShotStyle.px(120, scale: scale)
        let x: Int
        if selection.right + gap + width <= display.right {
            x = selection.right + gap
        } else if selection.x - gap - width >= display.x {
            x = selection.x - gap - width
        } else {
            return
        }
        let room = max(display.h - gap * 2, 1)
        guard let thumb = long.stitcher.thumbnail(maxWidth: width, maxHeight: room),
              let image = ComposedImage(width: thumb.width, rgbx: thumb.rgbx)?.cgImage() else { return }
        let top = max(min(max(selection.y, display.y + gap), display.bottom - gap - thumb.height), display.y)
        ShotRenderer.draw(image, in: CGRect(x: x, y: top, width: thumb.width, height: thumb.height), of: ctx)
        ShotRenderer.frame(
            PixelRect(x - 1, top - 1, thumb.width + 2, thumb.height + 2),
            ShotRenderer.colour(ShotRenderer.accent), thickness: 1, in: ctx)
    }
}
