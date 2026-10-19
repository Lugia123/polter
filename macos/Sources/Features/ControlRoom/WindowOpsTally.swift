import Foundation
import os

/// How many window operations the control room and the tabs caused, said
/// once a minute in the log (task 1873).
///
/// The window server stalled for seconds at a time while a test instance
/// ran in a background session, and none of these were in the log: a
/// terminal lent and given back, the control room's occlusion changing, a
/// tab's glyph ticking, its mark drawn again, a window's title set. Most of
/// them happen too often for a line each, so they are counted and the
/// counts are said together, to be laid beside the times of the stalls.
///
/// A minute with nothing counted says nothing, and the clock stops until
/// something is counted again: a quiet application does not wake for this.
@MainActor
enum WindowOpsTally {
    enum Op: String, CaseIterable {
        case borrow, giveBack, occlusionFlips, becomeKey, fixTabBar, markRedraw, titleSets, glyphTicks
        /// The bundle's icon set (`AppIconUpdater`) and the Dock's badge
        /// set (`AppDelegate.setDockBadge`): both go through LaunchServices.
        case setIcon, badgeSets
    }

    static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.mitchellh.ghostty",
        category: "window-ops")

    static let period: TimeInterval = 60

    private static var counts: [Op: Int] = [:]
    private static var clock: Timer?

    static func count(_ op: Op) {
        counts[op, default: 0] += 1
        guard clock == nil else { return }
        let timer = Timer(timeInterval: period, repeats: true) { _ in
            MainActor.assumeIsolated { say() }
        }
        RunLoop.main.add(timer, forMode: .common)
        clock = timer
    }

    /// The line for `counts`; nil when nothing was counted.
    nonisolated static func line(_ counts: [Op: Int]) -> String? {
        guard counts.values.contains(where: { $0 > 0 }) else { return nil }
        return "window ops/min: " + Op.allCases.map { "\($0.rawValue)=\(counts[$0] ?? 0)" }.joined(separator: " ")
    }

    private static func say() {
        guard let line = line(counts) else {
            clock?.invalidate()
            clock = nil
            return
        }
        counts = [:]
        // Notice, not info: info is not kept on disk unless asked for.
        logger.notice("\(line, privacy: .public)")
    }
}
