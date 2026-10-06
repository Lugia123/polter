import Foundation

/// The frozen picture out of focus (`dev-docs/poltergeist/screenshot.md`,
/// 9.8.6): what is shown outside the selection, and what the toolbar's glass
/// is made of.
///
/// The overlay covers a picture this application already holds, so nothing
/// asks the system's compositor to blur anything: the picture is blurred
/// once, here, when the screen is frozen, and every frame after that only
/// copies from the result. The Windows host does the same arithmetic.
///
/// The blur is a Gaussian done the cheap way -- shrink by `k`, three passes
/// of a box blur each way, stretch back -- because the cost of a blur at
/// full size is the one thing that would be noticed when the hotkey is
/// pressed: on a 3600 x 2338 display the three steps are tens of
/// milliseconds, a full-size blur a third of a second.
///
/// Pixels are rows of R, G, B, X, top row first. The fourth byte is carried
/// along and means nothing.
enum ShotBlur {
    /// How a blur of a given size is done at a given scale: shrink by `k`,
    /// then box-blur with this radius.
    struct Plan: Equatable {
        var k: Int
        var radius: Int
    }

    /// The plan for a Gaussian of `sigma` points on a display scaled by
    /// `scale`.
    ///
    /// Three box passes `2r + 1` wide have a variance of
    /// `((2r + 1)^2 - 1) / 4`, so the width that gives `s` is
    /// `sqrt(4 s^2 + 1)`. Never less than a radius of one: a radius of zero
    /// is no blur at all, and a blur that is asked for and silently not
    /// done is a picture people believe is hidden.
    static func plan(sigma: Double, scale: Double) -> Plan {
        let k = Int(scale >= ShotLook.Glass.downsampleScaleAtLeast
            ? ShotLook.Glass.downsampleHi : ShotLook.Glass.downsampleLo)
        let s = sigma * scale / Double(k)
        let radius = Int((((4 * s * s + 1).squareRoot() - 1) / 2).rounded())
        return Plan(k: max(k, 1), radius: max(radius, 1))
    }

    /// A picture with its size.
    struct Picture: Equatable {
        var width: Int
        var height: Int
        var rgbx: [UInt8]

        /// Nil unless `rgbx` is `width x height x 4` bytes of something.
        init?(width: Int, height: Int, rgbx: [UInt8]) {
            guard width > 0, height > 0, rgbx.count == width * height * 4 else { return nil }
            self.width = width
            self.height = height
            self.rgbx = rgbx
        }
    }

    /// `picture` shrunk by `k`: each pixel the mean of a `k x k` block. A
    /// block cut short by the right or bottom edge is the mean of what
    /// there is of it.
    static func shrunk(_ picture: Picture, by k: Int) -> Picture {
        let k = max(k, 1)
        let w = picture.width, h = picture.height
        let sw = (w + k - 1) / k, sh = (h + k - 1) / k
        var out = [UInt8](repeating: 0, count: sw * sh * 4)
        picture.rgbx.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for sy in 0..<sh {
                    let y0 = sy * k, y1 = min(y0 + k, h)
                    for sx in 0..<sw {
                        let x0 = sx * k, x1 = min(x0 + k, w)
                        var r = 0, g = 0, b = 0
                        for y in y0..<y1 {
                            var p = (y * w + x0) * 4
                            for _ in x0..<x1 {
                                r += Int(src[p])
                                g += Int(src[p + 1])
                                b += Int(src[p + 2])
                                p += 4
                            }
                        }
                        let n = (y1 - y0) * (x1 - x0)
                        let d = (sy * sw + sx) * 4
                        dst[d] = UInt8(r / n)
                        dst[d + 1] = UInt8(g / n)
                        dst[d + 2] = UInt8(b / n)
                        dst[d + 3] = 255
                    }
                }
            }
        }
        return Picture(width: sw, height: sh, rgbx: out) ?? picture
    }

    /// One pass of a box blur along one direction: every pixel becomes the
    /// mean of the `2 radius + 1` around it, the edge pixel standing in for
    /// what is past the edge. `count` pixels, `stride` bytes apart.
    private static func boxPass(
        _ src: UnsafePointer<UInt8>, _ dst: UnsafeMutablePointer<UInt8>, count: Int, stride: Int, radius: Int
    ) {
        let window = 2 * radius + 1
        for channel in 0..<3 {
            var sum = 0
            for i in -radius...radius {
                sum += Int(src[min(max(i, 0), count - 1) * stride + channel])
            }
            for i in 0..<count {
                dst[i * stride + channel] = UInt8((sum + window / 2) / window)
                let leaving = max(i - radius, 0), entering = min(i + radius + 1, count - 1)
                sum += Int(src[entering * stride + channel]) - Int(src[leaving * stride + channel])
            }
        }
    }

    /// `picture` box-blurred `passes` times each way.
    static func boxBlurred(_ picture: Picture, radius: Int, passes: Int) -> Picture {
        guard radius > 0, passes > 0 else { return picture }
        let w = picture.width, h = picture.height
        var a = picture.rgbx
        var b = [UInt8](repeating: 255, count: a.count)
        a.withUnsafeMutableBufferPointer { pa in
            b.withUnsafeMutableBufferPointer { pb in
                guard let base = pa.baseAddress, let other = pb.baseAddress else { return }
                for _ in 0..<passes {
                    for y in 0..<h {
                        boxPass(base + y * w * 4, other + y * w * 4, count: w, stride: 4, radius: radius)
                    }
                    for x in 0..<w {
                        boxPass(other + x * 4, base + x * 4, count: h, stride: w * 4, radius: radius)
                    }
                }
            }
        }
        return Picture(width: w, height: h, rgbx: a) ?? picture
    }

    /// What is done to a colour on its way out of `stretched`.
    struct Tone: Equatable {
        /// 1 leaves the colour as it is; more is more vivid.
        var saturation: Double
        /// What every channel is multiplied by afterwards.
        var brightness: Double

        static let none = Tone(saturation: 1, brightness: 1)
    }

    /// The part of `small` that lies under `rect` of the full-size picture
    /// -- `small` being that picture shrunk by `k` -- stretched back to
    /// `rect`'s size, bilinear, with `tone` applied.
    ///
    /// `rect` is in full-size pixels and may be any part of the
    /// picture: the whole of it for the outside of the selection, the
    /// toolbar's rectangle for its glass.
    static func stretched(_ small: Picture, by k: Int, rect: PixelRect, tone: Tone) -> Picture? {
        let x = rect.x, y = rect.y, width = rect.w, height = rect.h
        guard width > 0, height > 0, k > 0 else { return nil }
        let sw = small.width, sh = small.height
        var out = [UInt8](repeating: 255, count: width * height * 4)
        // Fixed point, eight bits: a pixel of the small picture is centred
        // on the middle of the block it was made from.
        let saturation = Int((tone.saturation * 256).rounded())
        let brightness = Int((tone.brightness * 256).rounded())
        let plain = saturation == 256 && brightness == 256
        // The weights of a colour's lightness, in 1/4096ths.
        let lumaR = Int((ShotLook.Glass.lumaR * 4096).rounded())
        let lumaG = Int((ShotLook.Glass.lumaG * 4096).rounded())
        let lumaB = Int((ShotLook.Glass.lumaB * 4096).rounded())
        // Rows are independent, so they are shared out: this is the one
        // step that touches every pixel of the display, and the one that is
        // waited for when the screen is frozen.
        let bands = max(min(ProcessInfo.processInfo.activeProcessorCount, height / 64), 1)
        small.rgbx.withUnsafeBufferPointer { source in
            out.withUnsafeMutableBufferPointer { target in
                // Each band writes its own rows and only reads the source.
                nonisolated(unsafe) let src = source
                nonisolated(unsafe) let dst = target
                DispatchQueue.concurrentPerform(iterations: bands) { band in
                for row in (height * band / bands)..<(height * (band + 1) / bands) {
                    var fy = ((y + row) * 256 + 128) / k - 128
                    fy = min(max(fy, 0), (sh - 1) * 256)
                    let y0 = fy >> 8, wy = fy & 255, y1 = min(y0 + 1, sh - 1)
                    let r0 = y0 * sw * 4, r1 = y1 * sw * 4
                    var d = row * width * 4
                    for column in 0..<width {
                        var fx = ((x + column) * 256 + 128) / k - 128
                        fx = min(max(fx, 0), (sw - 1) * 256)
                        let x0 = fx >> 8, wx = fx & 255, x1 = min(x0 + 1, sw - 1)
                        var v = (0, 0, 0)
                        func mix(_ c: Int) -> Int {
                            let top = Int(src[r0 + x0 * 4 + c]) * (256 - wx) + Int(src[r0 + x1 * 4 + c]) * wx
                            let bottom = Int(src[r1 + x0 * 4 + c]) * (256 - wx) + Int(src[r1 + x1 * 4 + c]) * wx
                            return (top * (256 - wy) + bottom * wy + 32768) >> 16
                        }
                        v.0 = mix(0)
                        v.1 = mix(1)
                        v.2 = mix(2)
                        if !plain {
                            let luma = (v.0 * lumaR + v.1 * lumaG + v.2 * lumaB + 2048) >> 12
                            func tuned(_ c: Int) -> Int {
                                let vivid = luma + (((c - luma) * saturation) >> 8)
                                return min(max((vivid * brightness) >> 8, 0), 255)
                            }
                            v = (tuned(v.0), tuned(v.1), tuned(v.2))
                        }
                        dst[d] = UInt8(v.0)
                        dst[d + 1] = UInt8(v.1)
                        dst[d + 2] = UInt8(v.2)
                        d += 4
                    }
                }
                }
            }
        }
        return Picture(width: width, height: height, rgbx: out)
    }

    /// What a display needs when its screen is frozen: the picture shrunk,
    /// kept sharp for the toolbar's glass, and the picture as it is shown
    /// outside the selection.
    struct Prepared {
        /// How much `small` was shrunk by.
        var k: Int
        /// The picture shrunk by `k`, not blurred.
        var small: Picture
        /// The whole picture blurred by `ShotLook.Glass.outsideBlurSigma`
        /// points and darkened by `ShotLook.Colour.outsideDim`.
        var outside: Picture
    }

    /// Everything for one display, from its frozen picture. Done once.
    static func prepare(_ picture: Picture, scale: Double) -> Prepared? {
        let plan = plan(sigma: ShotLook.Glass.outsideBlurSigma, scale: scale)
        let small = shrunk(picture, by: plan.k)
        let soft = boxBlurred(small, radius: plan.radius, passes: Int(ShotLook.Glass.boxPasses))
        // Darkening is a multiplication of every channel: black laid over
        // at `a` leaves `1 - a` of what was there.
        let tone = Tone(saturation: 1, brightness: 1 - ShotLook.Colour.outsideDim.a)
        guard let outside = stretched(
            soft, by: plan.k, rect: PixelRect(0, 0, picture.width, picture.height), tone: tone) else { return nil }
        return Prepared(k: plan.k, small: small, outside: outside)
    }

    /// The glass under a plate: the part of the picture under `rect`, in the
    /// display's own pixels, blurred by `ShotLook.Glass.plateBlurSigma` points, more
    /// vivid and darker. Computed from the small picture and only for the
    /// plate, so it costs next to nothing; done again when the plate moves.
    static func plate(from prepared: Prepared, scale: Double, rect: PixelRect) -> Picture? {
        let x = rect.x, y = rect.y, width = rect.w, height = rect.h
        guard width > 0, height > 0 else { return nil }
        let k = prepared.k
        let small = prepared.small
        let s = ShotLook.Glass.plateBlurSigma * scale / Double(k)
        let radius = max(Int((((4 * s * s + 1).squareRoot() - 1) / 2).rounded()), 1)
        // The plate's part of the small picture, with room around it for the
        // blur to reach into: three passes reach three radii.
        let margin = radius * Int(ShotLook.Glass.boxPasses) + 1
        let left = min(max(x / k - margin, 0), small.width - 1)
        let top = min(max(y / k - margin, 0), small.height - 1)
        let right = min(max((x + width + k - 1) / k + margin, left + 1), small.width)
        let bottom = min(max((y + height + k - 1) / k + margin, top + 1), small.height)
        let cw = right - left, ch = bottom - top
        var cut = [UInt8](repeating: 255, count: cw * ch * 4)
        for row in 0..<ch {
            let from = ((top + row) * small.width + left) * 4
            cut.replaceSubrange((row * cw * 4)..<((row + 1) * cw * 4), with: small.rgbx[from..<(from + cw * 4)])
        }
        guard let part = Picture(width: cw, height: ch, rgbx: cut) else { return nil }
        let soft = boxBlurred(part, radius: radius, passes: Int(ShotLook.Glass.boxPasses))
        let tone = Tone(saturation: ShotLook.Glass.plateSaturation, brightness: ShotLook.Glass.plateBrightness)
        return stretched(soft, by: k, rect: PixelRect(x - left * k, y - top * k, width, height), tone: tone)
    }
}
