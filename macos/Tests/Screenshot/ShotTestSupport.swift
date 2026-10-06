import Foundation
@testable import Ghostty

/// The generator the Windows host's tests use, so that a fixture here is
/// the same bytes as the fixture there.
struct ShotLcg {
    var state: UInt64

    init(_ seed: UInt64) { state = seed }

    mutating func next() -> UInt32 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return UInt32(truncatingIfNeeded: state >> 33)
    }
}

enum ShotFixtures {
    /// `pixels` pixels of noise, four bytes each, the fourth zero.
    static func noise(pixels: Int, seed: UInt64) -> [UInt8] {
        var g = ShotLcg(seed)
        var out: [UInt8] = []
        out.reserveCapacity(pixels * 4)
        for _ in 0..<pixels {
            let v = g.next()
            out.append(UInt8(truncatingIfNeeded: v))
            out.append(UInt8(truncatingIfNeeded: v >> 8))
            out.append(UInt8(truncatingIfNeeded: v >> 16))
            out.append(0)
        }
        return out
    }

    static func frozen(_ rect: PixelRect, seed: UInt64) -> FrozenImage {
        FrozenImage(rect: rect, rgbx: noise(pixels: rect.w * rect.h, seed: seed))!
    }

    static func pixel(_ buffer: [UInt8], width: Int, _ x: Int, _ y: Int) -> [UInt8] {
        let at = (y * width + x) * 4
        return Array(buffer[at..<(at + 4)])
    }

    /// An annotation in the default colour at the default step.
    static func item(_ shape: Annotation.Shape) -> Annotation {
        Annotation(shape: shape, colour: 0, level: 1)
    }

    /// A text whose measured size is ten pixels a character, eighteen tall.
    static func text(_ at: PixelPoint, _ s: String) -> Annotation.Shape {
        .text(at: at, text: s, size: .init(s.count * 10, 18))
    }

    static func number(_ n: Int, _ at: PixelPoint, _ s: String) -> Annotation.Shape {
        .number(n: n, at: at, text: s, size: .init(s.count * 10, s.isEmpty ? 0 : 18))
    }
}
