import Foundation

/// v8 (3178): p is a fraction of physical memory, never of a kill line.
/// Parameters, event priorities and solid colours come from the shared look.
enum ControlRoomPerfColor {
    typealias Look = ControlRoomLook
    typealias Band = Look.PerfLoad
    enum Event: CaseIterable {
        case none, warn1, warn2, stopped
        var priority: Double {
            switch self {
            case .none: Band.priorityNone
            case .warn1: Band.priorityWarn1
            case .warn2: Band.priorityWarn2
            case .stopped: Band.priorityStopped
            }
        }
    }

    static func highest(_ events: [Event]) -> Event {
        events.reduce(.none) { $1.priority > $0.priority ? $1 : $0 }
    }

    static func load(_ fraction: Double) -> Look.RGBA {
        let p = fraction.isFinite ? min(1, max(0, fraction)) : 0
        let t = pow(p, Band.power)
        let l = Band.l0 + (Band.l1 - Band.l0) * t
        let c = Band.c0 + (Band.c1 - Band.c0) * t
        let h = Band.hue * .pi / 180
        let a = c * cos(h), b = c * sin(h)
        let x = pow(l + 0.3963377774 * a + 0.2158037573 * b, 3)
        let y = pow(l - 0.1055613458 * a - 0.0638541728 * b, 3)
        let z = pow(l - 0.0894841775 * a - 1.2914855480 * b, 3)
        func byte(_ v: Double) -> UInt8 {
            let srgb = v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055
            return UInt8((min(1, max(0, srgb)) * 255).rounded())
        }
        return .init(r: byte(4.0767416621 * x - 3.3077115913 * y + 0.2309699292 * z),
                     g: byte(-1.2684380046 * x + 2.6097574011 * y - 0.3413193965 * z),
                     b: byte(-0.0041960863 * x - 0.7034186147 * y + 1.7076147010 * z), a: 1)
    }

    static func paint(_ fraction: Double?, event: Event, theme: Look.Theme) -> Look.RGBA {
        switch event {
        case .warn1: theme.perfEventWarn1
        case .warn2: theme.perfEventWarn2
        case .stopped: theme.perfEventStopped
        case .none: fraction.map(load) ?? theme.levelOk
        }
    }

    static func curveEvent(_ fraction: Double, warnings: [Double], stopped: Bool) -> Event {
        var events: [Event] = stopped ? [.stopped] : []
        for (index, threshold) in warnings.enumerated() where fraction >= threshold {
            events.append(index == 0 ? .warn1 : .warn2)
        }
        return highest(events)
    }

}
