import AppKit
import Carbon.HIToolbox
import OSLog

/// A system-wide hotkey registered with `RegisterEventHotKey`.
///
/// This, and not the event tap the other `global:` keybinds go through, is
/// what the screenshot hotkey uses: the tap needs the Accessibility
/// permission and a registered hotkey needs none
/// (`dev-docs/poltergeist/screenshot.md`, 3.1).
final class ShotGlobalHotKey {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var action: (() -> Void)?

    /// What is registered now, so that a config reload that changes nothing
    /// does not unregister and register again.
    private(set) var registered: ShotHotKey.Spec?

    /// 'PSHT', and one id: there is one screenshot hotkey.
    private static let signature: OSType = 0x5053_4854
    private static let identifier: UInt32 = 1

    deinit { unregister() }

    /// Register `spec`, replacing whatever was registered. Returns the
    /// status `RegisterEventHotKey` gave: `noErr`, or the reason it refused
    /// (`eventHotKeyExistsErr` when another registration has the chord).
    @discardableResult
    func register(_ spec: ShotHotKey.Spec, action: @escaping () -> Void) -> OSStatus {
        unregister()
        self.action = action

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var id = EventHotKeyID()
                let got = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &id)
                guard got == noErr,
                      id.signature == ShotGlobalHotKey.signature,
                      id.id == ShotGlobalHotKey.identifier else {
                    return OSStatus(eventNotHandledErr)
                }
                let this = Unmanaged<ShotGlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
                this.action?()
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handler)
        guard installed == noErr else {
            self.action = nil
            return installed
        }

        let id = EventHotKeyID(signature: Self.signature, id: Self.identifier)
        let status = RegisterEventHotKey(
            spec.keyCode, spec.modifiers, id, GetApplicationEventTarget(), 0, &hotKey)
        if status == noErr {
            registered = spec
        } else {
            unregister()
        }
        return status
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil
        handler = nil
        action = nil
        registered = nil
    }
}

/// Modifiers held plus a double-click of the left button, anywhere on
/// screen.
///
/// A global monitor for mouse-down events needs neither the Accessibility
/// nor the Input Monitoring permission (measured on an untrusted process:
/// both checks answered no and the presses still arrived). It observes and
/// cannot consume, so both clicks also reach whatever is under the pointer.
final class ShotMouseTrigger {
    /// The longest distance between the two presses. macOS publishes its
    /// double-click interval and not its double-click distance, so this is
    /// ours; it matches the selection's own click-or-drag threshold.
    static let distance: CGFloat = 4

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "polter",
        category: String(describing: ShotMouseTrigger.self)
    )

    private var detector: DoubleClickDetector
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private let fire: (CGPoint) -> Void

    /// - Parameter fire: called on the main thread with where the pointer
    ///   was, in AppKit's global coordinates.
    init(required: ShotMods, fire: @escaping (CGPoint) -> Void) {
        self.detector = DoubleClickDetector(
            required: required,
            interval: NSEvent.doubleClickInterval,
            distance: Self.distance)
        self.fire = fire
    }

    deinit { stop() }

    var required: ShotMods { detector.required }

    func start() {
        guard globalMonitor == nil else { return }
        // Presses in other applications.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.pressed(event, from: "global")
        }
        // And in our own windows, which the global monitor does not report.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.pressed(event, from: "local")
            return event
        }
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }

    private func pressed(_ event: NSEvent, from monitor: String) {
        let point = NSEvent.mouseLocation
        let mods = ShotMods(event.modifierFlags)
        let verdict = detector.press(at: point, time: event.timestamp, mods: mods)
        // Only presses made with the modifiers held are worth a line: the
        // rest is every click on the machine.
        if verdict != .wrongModifiers {
            Self.logger.info("screenshot: press monitor=\(monitor, privacy: .public) number=\(event.eventNumber, privacy: .public) time=\(event.timestamp, privacy: .public) clicks=\(event.clickCount, privacy: .public) appActive=\(NSApp.isActive, privacy: .public) -> \(String(describing: verdict), privacy: .public)")
        }
        guard verdict == .fired else { return }
        // Not from inside the monitor: what this starts may run a dialog,
        // and the monitor must have returned the press by then.
        DispatchQueue.main.async { [fire] in fire(point) }
    }
}

extension ShotMods {
    init(_ flags: NSEvent.ModifierFlags) {
        var mods: ShotMods = []
        if flags.contains(.shift) { mods.insert(.shift) }
        if flags.contains(.control) { mods.insert(.control) }
        if flags.contains(.option) { mods.insert(.option) }
        if flags.contains(.command) { mods.insert(.command) }
        self = mods
    }
}
