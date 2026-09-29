import Foundation
import Testing
@testable import Compositor

/// Times the profile engine. Run on request (`TEST_RUNNER_PROFILE_BENCHMARK=1`), preferably in Release: the targets
/// on the Mac Studio are a 256³ bake under 250 ms and a 24 MP LUT apply under 50 ms. Nothing here asserts a time.
struct ProfilePerformanceTests {
    @Test func bakeAndApply() throws {
        guard ProcessInfo.processInfo.environment["PROFILE_BENCHMARK"] == "1" else { return }
        let warm = try ProfileFixtureFiles.loaded("profile-warm-adobe.xmp")
        func milliseconds(_ body: () -> Void) -> Double {
            let start = CFAbsoluteTimeGetCurrent()
            body()
            return (CFAbsoluteTimeGetCurrent() - start) * 1000
        }

        let program = ProfileProgram(profile: warm.profile, percent: 100)
        _ = ProfileLUT.bake(program)
        let bake = milliseconds { _ = ProfileLUT.bake(program) }

        ProfileLUTCache.removeAll()
        _ = ProfileLUTCache.lut(for: warm, percent: 100)
        var large = Self.pixels(width: 6000, height: 4000)
        let lut = milliseconds {
            large.withUnsafeMutableBufferPointer { buffer in
                ProfileRenderer.apply(pixels: buffer.baseAddress!, width: 6000, height: 4000, stride: 6000 * 4,
                                      profile: warm, percent: 100)
            }
        }

        var small = Self.pixels(width: 1024, height: 1024)
        let direct = milliseconds {
            small.withUnsafeMutableBufferPointer { buffer in
                ProfileRenderer.apply(pixels: buffer.baseAddress!, width: 1024, height: 1024, stride: 1024 * 4,
                                      profile: warm, percent: 60)
            }
        }
        ProfileLUTCache.removeAll()
        print(String(format: "Profile engine: 256³ bake %.1f ms, 24 MP LUT apply %.1f ms, 1 MP direct apply %.1f ms",
                     bake, lut, direct))
    }

    /// Opaque pixels with many distinct colours, so neither path can lean on repetition.
    static func pixels(width: Int, height: Int) -> [UInt8] {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        var state: UInt32 = 7
        for pixel in 0 ..< width * height {
            state = state &* 1_664_525 &+ 1_013_904_223
            pixels[pixel * 4] = UInt8(truncatingIfNeeded: state >> 8)
            pixels[pixel * 4 + 1] = UInt8(truncatingIfNeeded: state >> 16)
            pixels[pixel * 4 + 2] = UInt8(truncatingIfNeeded: state >> 24)
        }
        return pixels
    }
}
