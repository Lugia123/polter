import AppKit
import CoreGraphics
import ScreenCaptureKit

/// One display, frozen.
struct ShotDisplay {
    let screen: NSScreen
    /// The picture, for showing.
    let image: CGImage
    /// The display's frame in CoreGraphics' global coordinates: points,
    /// origin at the top left of the primary display, y downwards. This is
    /// the space the window list is in.
    let frame: CGRect
}

/// A window as it was when the screen was frozen.
struct ShotWindow: Equatable {
    var id: UInt64
    /// In the same global coordinates as `ShotDisplay.frame`.
    var frame: CGRect
    var app: String?
    var title: String?
    var pid: Int?
}

/// Freezing the screen and listing what is on it.
enum ShotCapture {
    /// Whether this app may record the screen. Without it a capture comes
    /// back as the desktop picture with no windows on it, which must never
    /// be saved as though it were a screenshot.
    static var isPermitted: Bool { CGPreflightScreenCaptureAccess() }

    /// Ask for the permission. The first call puts up the system's prompt;
    /// later ones do nothing.
    static func requestPermission() { _ = CGRequestScreenCaptureAccess() }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// Every display as it is right now.
    ///
    /// ScreenCaptureKit's screenshot call is macOS 14 and later; macOS 13,
    /// which this app still supports, has only the CoreGraphics one, which
    /// in turn is gone from macOS 15. So each is used where it exists.
    static func captureAll(completion: @escaping ([ShotDisplay]) -> Void) {
        let screens = NSScreen.screens
        if #available(macOS 14.0, *) {
            Task {
                var displays: [ShotDisplay] = []
                if let content = try? await SCShareableContent.excludingDesktopWindows(
                    false, onScreenWindowsOnly: true) {
                    for screen in screens {
                        guard let id = displayID(of: screen),
                              let display = content.displays.first(where: { $0.displayID == id }) else { continue }
                        let configuration = SCStreamConfiguration()
                        let scale = screen.backingScaleFactor
                        configuration.width = Int((CGFloat(display.width) * scale).rounded())
                        configuration.height = Int((CGFloat(display.height) * scale).rounded())
                        configuration.showsCursor = false
                        let filter = SCContentFilter(display: display, excludingWindows: [])
                        guard let image = try? await SCScreenshotManager.captureImage(
                            contentFilter: filter, configuration: configuration) else { continue }
                        displays.append(ShotDisplay(screen: screen, image: image, frame: CGDisplayBounds(id)))
                    }
                }
                let captured = displays
                await MainActor.run { completion(captured) }
            }
        } else {
            let displays: [ShotDisplay] = screens.compactMap { screen in
                guard let id = displayID(of: screen),
                      let image = legacyImage(of: id) else { return nil }
                return ShotDisplay(screen: screen, image: image, frame: CGDisplayBounds(id))
            }
            completion(displays)
        }
    }

    @available(macOS, deprecated: 14.0)
    private static func legacyImage(of display: CGDirectDisplayID) -> CGImage? {
        CGDisplayCreateImage(display)
    }

    /// The ordinary windows on screen, front to back, in global CoreGraphics
    /// coordinates. Taken before the overlay goes up, so the overlay is not
    /// in it.
    static func windows() -> [ShotWindow] {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return [] }

        return list.compactMap { info in
            // Layer 0 is where applications' own windows are; the menu bar,
            // the Dock and overlays are above it.
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let number = info[kCGWindowNumber as String] as? Int,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width >= 1, bounds.height >= 1 else { return nil }
            return ShotWindow(
                id: UInt64(number),
                frame: bounds,
                app: info[kCGWindowOwnerName as String] as? String,
                title: info[kCGWindowName as String] as? String,
                pid: info[kCGWindowOwnerPID as String] as? Int)
        }
    }
}

/// Taking frames of one part of one display as it is *now*, with this app's
/// overlay left out: what a long screenshot is stitched from
/// (`dev-docs/poltergeist/screenshot.md`, 9.6).
final class ShotLiveCapture {
    private let displayID: CGDirectDisplayID
    /// The part to take, in the display's own points.
    private let region: CGRect
    /// The size of a frame in pixels.
    private let pixels: Annotation.PixelSize
    /// The overlay windows, which are not part of the picture.
    private let overlayNumbers: [Int]
    private var busy = false
    /// What ScreenCaptureKit needs, found once.
    private var prepared: Any?

    init(displayID: CGDirectDisplayID, region: CGRect, pixels: Annotation.PixelSize, overlayNumbers: [Int]) {
        self.displayID = displayID
        self.region = region
        self.pixels = pixels
        self.overlayNumbers = overlayNumbers
    }

    /// Take one frame. `completion` is called on the main thread with the
    /// frame as rows of R, G, B, X, or nil when there is none -- including
    /// when the previous frame is still being taken, which is not waited
    /// for: a frame that arrives late is a frame of an earlier moment.
    func frame(completion: @escaping ([UInt8]?) -> Void) {
        guard !busy else {
            completion(nil)
            return
        }
        busy = true
        let finish: (CGImage?) -> Void = { [weak self] image in
            let size = self?.pixels
            DispatchQueue.global(qos: .userInitiated).async {
                var bytes = image.flatMap(ShotRenderer.rgbx(of:))
                if let size, let image, image.width != size.w || image.height != size.h { bytes = nil }
                DispatchQueue.main.async {
                    self?.busy = false
                    completion(bytes)
                }
            }
        }

        if #available(macOS 14.0, *) {
            Task { [displayID, region, pixels, overlayNumbers] in
                var filter = await MainActor.run { self.prepared as? SCContentFilter }
                if filter == nil,
                   let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
                   let display = content.displays.first(where: { $0.displayID == displayID }) {
                    let ours = content.windows.filter { overlayNumbers.contains(Int($0.windowID)) }
                    let made = SCContentFilter(display: display, excludingWindows: ours)
                    await MainActor.run { self.prepared = made }
                    filter = made
                }
                guard let filter else {
                    finish(nil)
                    return
                }
                let configuration = SCStreamConfiguration()
                configuration.sourceRect = region
                configuration.width = pixels.w
                configuration.height = pixels.h
                configuration.showsCursor = false
                finish(try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration))
            }
        } else {
            let origin = CGDisplayBounds(displayID).origin
            let global = region.offsetBy(dx: origin.x, dy: origin.y)
            finish(Self.legacyImage(of: global, below: overlayNumbers.first))
        }
    }

    @available(macOS, deprecated: 14.0)
    private static func legacyImage(of rect: CGRect, below window: Int?) -> CGImage? {
        guard let window else { return nil }
        return CGWindowListCreateImage(rect, .optionOnScreenBelowWindow, CGWindowID(window), [.bestResolution])
    }
}
