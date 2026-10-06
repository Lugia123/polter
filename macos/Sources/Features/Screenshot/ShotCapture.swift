import AppKit
import CoreGraphics
import ScreenCaptureKit

/// One display, frozen.
struct ShotDisplay {
    let screen: NSScreen
    let image: CGImage
    /// The display's frame in CoreGraphics' global coordinates: points,
    /// origin at the top left of the primary display, y downwards. This is
    /// the space the window list is in.
    let frame: CGRect

    /// Pixels of `image` per point. Read off the image rather than the
    /// screen's backing scale: what was captured is what gets cropped.
    var scale: CGFloat { frame.width > 0 ? CGFloat(image.width) / frame.width : 1 }

    var imageSize: CGSize { CGSize(width: image.width, height: image.height) }
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
    static func windows() -> [ShotGeometry.Window] {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return [] }

        return list.compactMap { info in
            // Layer 0 is where applications' own windows are; the menu bar,
            // the Dock and overlays are above it.
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width >= 1, bounds.height >= 1 else { return nil }
            return ShotGeometry.Window(
                frame: bounds,
                app: info[kCGWindowOwnerName as String] as? String,
                title: info[kCGWindowName as String] as? String)
        }
    }
}
