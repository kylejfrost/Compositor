import CoreGraphics
import Foundation
import simd
import Testing
@testable import Compositor

/// The profile engine: colour spaces, transfer functions, curves, amounts, the table stages against the Python
/// reference, the premultiplied kernels, and the LUT cache. Serialized because the cache tests count bakes.
@Suite(.serialized)
struct ProfileRenderingTests {
    @Test func colourMatricesMatchTheSDK() {
        func expect(_ matrix: simd_double3x3, row: Int, _ values: [Double], _ label: String) {
            for column in 0 ..< 3 {
                // simd matrices are column-major: matrix[column][row].
                #expect(abs(matrix[column][row] - values[column]) <= 1e-9, "\(label) [\(row)][\(column)]")
            }
        }
        func expect(_ matrix: simd_double3x3, _ rows: [[Double]], _ label: String) {
            for (row, values) in rows.enumerated() { expect(matrix, row: row, values, label) }
        }
        expect(ProfileColorSpaces.matrix(from: .sRGB, to: .proPhoto),
               [[0.529299315, 0.3300507607, 0.1406499243], [0.0984128566, 0.8734844959, 0.0281026474],
                [0.0168464429, 0.1176827051, 0.865470852]], "sRGB → ProPhoto")
        expect(ProfileColorSpaces.matrix(from: .proPhoto, to: .sRGB),
               [[2.0342894559, -0.7273081487, -0.3069813072], [-0.2289247533, 1.2317165835, -0.0027918302],
                [-0.0084694439, -0.1533260005, 1.1617954445]], "ProPhoto → sRGB")
        expect(ProfileColorSpaces.matrix(from: .proPhoto, to: .adobeRGB),
               [[1.3897561694, -0.1694395557, -0.2203166137], [-0.2289215987, 1.2317390654, -0.0028174667],
                [-0.0176724684, -0.096305181, 1.1139776493]], "ProPhoto → AdobeRGB")
        expect(ProfileColorSpaces.matrix(from: .proPhoto, to: .displayP3), row: 0,
               [1.6327035088, -0.3798365328, -0.252866976], "ProPhoto → Display P3")
        expect(ProfileColorSpaces.matrix(from: .proPhoto, to: .rec2020), row: 0,
               [1.2007747331, -0.0575482371, -0.143226496], "ProPhoto → Rec. 2020")
        let gray = ProfileColorSpaces.grayWeights
        #expect(abs(gray.x - 0.2880) <= 1e-12 && abs(gray.y - 0.7119) <= 1e-12 && abs(gray.z - 0.0001) <= 1e-12)
    }

    @Test func transferFunctionsMatchTheReference() {
        let encoded: [(gamma: Int32, x: Double, y: Double)] = [
            (3, 0.001, 0.0294911420), (3, 0.18, 0.4586564469), (3, 0.5, 0.7297400528), (3, 0.0034800731, 0.0763027458),
            (2, 0.5, 0.6803950001), (4, 0.01, 0.045), (4, 0.5, 0.7054355531), (1, 0.18, 0.4613561295),
        ]
        for (gamma, x, y) in encoded {
            #expect(abs(profile_transfer_encode(gamma, x) - y) <= 2e-5, "encode(\(gamma), \(x))")
        }
        #expect(abs(profile_transfer_decode(3, 0.5) - 0.2176376408) <= 2e-5)
        #expect(abs(profile_transfer_decode(3, 0.03) - 0.0010190064) <= 2e-5)
        // γ1.8's toe (x below 8.2e-4) spans 3.4 cells of the 4097-entry table and bends sharply, so the table, like
        // the SDK's, is up to 2e-4 away from the exact curve there.
        #expect(abs(profile_transfer_encode(2, 0.0004) - 0.0113435204) <= 2e-4)
        for gamma: Int32 in 1 ... 4 {
            var worst = 0.0, worstNearBlack = 0.0
            for index in 0 ..< 1000 {
                let y = Double(index) / 999
                let error = abs(profile_transfer_encode(gamma, profile_transfer_decode(gamma, y)) - y)
                if y < 0.1 { worstNearBlack = max(worstNearBlack, error) } else { worst = max(worst, error) }
            }
            #expect(worst <= 5e-5, "gamma \(gamma): \(worst)")
            #expect(worstNearBlack <= 2.5e-4, "gamma \(gamma) near black: \(worstNearBlack)")
            if gamma == 1 || gamma == 4 { #expect(worstNearBlack <= 5e-5, "gamma \(gamma) near black: \(worstNearBlack)") }
        }
    }

    @Test func splineMatchesDNGSolver() throws {
        let spline = ProfileSpline(x: [0, 0.25, 0.75, 1], y: [0, 0.18, 0.85, 1])
        #expect(spline.slopes.count == 4)
        for (slope, expected) in zip(spline.slopes, [0.5575, 1.045, 0.955, 0.4225]) {
            #expect(abs(slope - expected) <= 1e-12)
        }
        #expect(abs(spline(0.1) - 0.05835) <= 1e-9)
        #expect(abs(spline(0.5) - 0.520625) <= 1e-9)
        #expect(abs(spline(0.9) - 0.95491) <= 1e-9)
        #expect(spline(-0.2) == 0)
        #expect(spline(1.2) == 1)

        let line = try #require(ProfileToneCurve(points: [ProfileCurvePoint(x: 0, y: 10), ProfileCurvePoint(x: 255, y: 250)]))
        for index in 0 ... 20 {
            let x = Double(index) / 20
            #expect(abs(line(x) - (10 + 240 * x) / 255) <= 1e-12)
        }
        #expect(ProfileToneCurve(points: [ProfileCurvePoint(x: 0, y: 0), ProfileCurvePoint(x: 255, y: 255)]) == nil)
        #expect(ProfileToneCurve(points: []) == nil)
        let samples = line.samples()
        #expect(samples.count == 4097)
        #expect(abs(Double(samples[2048]) - line(0.5)) <= 1e-6)
    }

    @Test func amountsFollowTheSDK() throws {
        #expect(ProfileRenderer.sdkAmount(0.1125, 0, 2) == 0.11)
        #expect(ProfileRenderer.sdkAmount(1.125, 0, 1.5) == 113 * 0.01)
        #expect(ProfileRenderer.sdkAmount(0.5, 0, 2) == 0.5)
        #expect(ProfileRenderer.sdkAmount(2, 0, 1) == 1)
        #expect(ProfileRenderer.sdkAmount(0, 0, 2) == 0)

        let warm = try ProfileFixtureFiles.loaded("profile-warm-adobe.xmp").profile
        #expect(ProfileRenderer.amounts(for: warm, percent: 100) == ProfileStageAmounts(look: nil, rgb: 0.5))
        #expect(ProfileRenderer.amounts(for: warm, percent: 150) == ProfileStageAmounts(look: nil, rgb: 0.75))
        #expect(ProfileRenderer.amounts(for: warm, percent: 0) == ProfileStageAmounts(look: nil, rgb: 0))
        let noAmount = try ProfileFixtureFiles.loaded("profile-no-amount.xmp").profile
        #expect(ProfileRenderer.amounts(for: noAmount, percent: 200).rgb == 0.5)

        let fixed = try ProfileFixtureFiles.loaded("profile-hsm-srgb-fixed.xmp").profile
        let scaled = ProfileRenderOptions(fixedLookTables: .scaledWithAmount)
        #expect(ProfileRenderer.amounts(for: fixed, percent: 0).look == 1)
        #expect(ProfileRenderer.amounts(for: fixed, percent: 0, options: scaled).look == 0)
        #expect(ProfileRenderer.amounts(for: fixed, percent: 50, options: scaled).look == 0.5)
        #expect(ProfileRenderer.amounts(for: fixed, percent: 150, options: scaled).look == 1)
        #expect(ProfileRenderer.amounts(for: fixed, percent: 0, options: ProfileRenderOptions(fixedLookTables: .skipped))
            == ProfileStageAmounts(look: nil, rgb: nil))
        let linear = try ProfileFixtureFiles.loaded("profile-hsm-linear.xmp").profile
        #expect(ProfileRenderer.amounts(for: linear, percent: 150) == ProfileStageAmounts(look: 1.5, rgb: nil))
    }

    struct Kernels: Decodable {
        struct Case: Decodable {
            let profile: String
            let stage: String
            let amount: Double
            let outputs: [[Double]]
        }
        let inputs: [[Double]]
        let cases: [Case]
    }

    @Test func kernelsMatchPython() throws {
        let kernels = try JSONDecoder().decode(Kernels.self, from: ProfileFixtureFiles.data("kernels.json"))
        #expect(kernels.inputs.count == 200)
        #expect(kernels.cases.count == 13)
        for kernel in kernels.cases {
            let profile = try ProfileFixtureFiles.loaded(kernel.profile).profile
            let look = kernel.stage == "look"
            let program = ProfileProgram(profile: profile, amounts: look ? ProfileStageAmounts(look: kernel.amount, rgb: nil)
                                                                          : ProfileStageAmounts(look: nil, rgb: kernel.amount))
            try #require(kernel.outputs.count == kernels.inputs.count)
            var worst = 0.0
            for (input, expected) in zip(kernels.inputs, kernel.outputs) {
                let x = SIMD3(input[0], input[1], input[2])
                let y = look ? program.hueSatMap(x) : program.rgbTable(x)
                worst = max(worst, simd_abs(y - SIMD3(expected[0], expected[1], expected[2])).max())
            }
            #expect(worst <= 2e-4, "\(kernel.profile) \(kernel.stage) at \(kernel.amount): \(worst)")
        }
    }

    @Test func premultipliedPixelsFollowTheKernelConventions() throws {
        let warm = try ProfileFixtureFiles.loaded("profile-warm-adobe.xmp")
        let program = ProfileProgram(profile: warm.profile, percent: 150)
        var pixels: [UInt8] = [64, 32, 16, 128, 9, 9, 9, 0, 200, 100, 50, 255]
        pixels.withUnsafeMutableBufferPointer { buffer in
            ProfileRenderer.apply(pixels: buffer.baseAddress!, width: 3, height: 1, stride: 12, profile: warm, percent: 150)
        }
        let half = program.evaluate(byte: SIMD3(128, 64, 32))
        #expect(Array(pixels[0 ..< 4]) == [0, 1, 2].map { UInt8((Int(half[$0]) * 128 + 127) / 255) } + [128])
        #expect(Array(pixels[4 ..< 8]) == [9, 9, 9, 0])
        let opaque = program.evaluate(byte: SIMD3(200, 100, 50))
        #expect(Array(pixels[8 ..< 12]) == [opaque.x, opaque.y, opaque.z, 255])
        // Pixel 1 keeps its garbage, so only the pixels the kernel wrote are checked.
        for pixel in [0, 2] {
            for channel in 0 ..< 3 { #expect(pixels[pixel * 4 + channel] <= pixels[pixel * 4 + 3]) }
        }
    }

    @Test func lutAndDirectAreIdentical() throws {
        let probe = try ProfileFixtureFiles.rgb(ProfileFixtureFiles.url("probe.png")).rgb
        for (name, percent) in [("profile-warm-adobe.xmp", 150), ("profile-bw-curve.xmp", 50)] {
            let program = ProfileProgram(profile: try ProfileFixtureFiles.loaded(name).profile, percent: percent)
            let lut = ProfileLUT.bake(program)
            var colours: [SIMD3<UInt8>] = stride(from: 0, to: probe.count, by: 3).map { SIMD3(probe[$0], probe[$0 + 1], probe[$0 + 2]) }
            var random = LCG(seed: 2026)
            for _ in 0 ..< 65536 { colours.append(SIMD3(random.byte(), random.byte(), random.byte())) }
            var mismatches = 0
            for colour in colours where lut[colour.x, colour.y, colour.z] != program.evaluate(byte: colour) { mismatches += 1 }
            #expect(mismatches == 0, "\(name): \(mismatches) of \(colours.count) colours differ")

            var direct = Self.randomPremultiplied(width: 64, height: 64, seed: UInt32(percent))
            var looked = direct
            direct.withUnsafeMutableBufferPointer { buffer in
                program.withProgram { profile_apply_direct(buffer.baseAddress, 64, 64, 256, $0) }
            }
            looked.withUnsafeMutableBufferPointer { buffer in
                profile_apply_lut(buffer.baseAddress, 64, 64, 256, UnsafePointer(lut.bytes.baseAddress))
            }
            #expect(direct == looked, "\(name): direct and LUT pixels differ")
        }
    }

    @Test func identityProfileIsExact() throws {
        let program = ProfileProgram(profile: try ProfileFixtureFiles.loaded("profile-identity-srgb.xmp").profile, percent: 100)
        let lut = ProfileLUT.bake(program)
        var mismatches = 0
        let bytes = UnsafeBufferPointer(lut.bytes)
        var index = 0
        for red in 0 ..< 256 {
            for green in 0 ..< 256 {
                for blue in 0 ..< 256 {
                    if bytes[index] != UInt8(red) || bytes[index + 1] != UInt8(green) || bytes[index + 2] != UInt8(blue) {
                        mismatches += 1
                    }
                    index += 3
                }
            }
        }
        #expect(mismatches == 0)
    }

    @Test func cacheBakesOnceAndEvicts() async throws {
        let warm = try ProfileFixtureFiles.loaded("profile-warm-adobe.xmp")
        ProfileLUTCache.removeAll()
        let key = ProfileLUTCache.key(for: warm, percent: 100, options: .standard)
        let before = ProfileLUTCache.bakeCount(for: key)
        let requests = (0 ..< 4).map { _ in Task.detached { ProfileLUTCache.lut(for: warm, percent: 100) } }
        var luts: [ProfileLUT] = []
        for request in requests { luts.append(await request.value) }
        #expect(ProfileLUTCache.bakeCount(for: key) == before + 1)
        #expect(luts.allSatisfy { $0 === luts[0] })

        for percent in [0, 50, 100, 150, 200] { _ = ProfileLUTCache.lut(for: warm, percent: percent) }
        #expect(ProfileLUTCache.cached(ProfileLUTCache.key(for: warm, percent: 0, options: .standard)) == nil)
        #expect(ProfileLUTCache.cached(ProfileLUTCache.key(for: warm, percent: 200, options: .standard)) != nil)

        let noAmount = try ProfileFixtureFiles.loaded("profile-no-amount.xmp")
        #expect(ProfileLUTCache.key(for: noAmount, percent: 30, options: .standard)
            == ProfileLUTCache.key(for: noAmount, percent: 200, options: .standard))
        ProfileLUTCache.removeAll()
    }

    /// What an insert evicts or replaces comes back to the caller, so a 48 MiB table is freed outside the cache's lock.
    @Test func lruInsertHandsBackWhatItRemoves() {
        var lru = ProfileLUTCache.LRU<Int>(capacity: 2)
        let keys = (0 ..< 3).map {
            ProfileLUTKey(digest: ProfileDigest(of: Data([UInt8($0)])), percent: 100, options: .standard, revision: 1)
        }
        #expect(lru.insert(0, for: keys[0]).isEmpty)
        #expect(lru.insert(1, for: keys[1]).isEmpty)
        #expect(lru.value(for: keys[0]) == 0)
        #expect(lru.insert(2, for: keys[2]) == [1])
        #expect(lru.insert(20, for: keys[2]) == [2])
        #expect(lru.entries.map(\.value) == [0, 20])
    }

    @Test func bigImagesUseTheLUTSmallOnesDoNot() throws {
        let warm = try ProfileFixtureFiles.loaded("profile-warm-adobe.xmp")
        let program = ProfileProgram(profile: warm.profile, percent: 50)
        ProfileLUTCache.removeAll()
        let key = ProfileLUTCache.key(for: warm, percent: 50, options: .standard)
        let before = ProfileLUTCache.bakeCount(for: key)
        for (width, height, bakes) in [(16, 16, 0), (1100, 1000, 1)] {
            var pixels = Self.randomPremultiplied(width: width, height: height, seed: UInt32(width))
            var expected = pixels
            pixels.withUnsafeMutableBufferPointer { buffer in
                ProfileRenderer.apply(pixels: buffer.baseAddress!, width: width, height: height, stride: width * 4,
                                      profile: warm, percent: 50)
            }
            #expect(ProfileLUTCache.bakeCount(for: key) == before + bakes, "\(width)×\(height)")
            expected.withUnsafeMutableBufferPointer { buffer in
                program.withProgram { profile_apply_direct(buffer.baseAddress, width, height, width * 4, $0) }
            }
            #expect(pixels == expected, "\(width)×\(height)")
        }
        ProfileLUTCache.removeAll()
    }

    /// The canvas's policy: a large image without a table is evaluated directly, giving the bytes the table gives,
    /// without the caller waiting for a bake; the table is baked off the caller's thread for later draws. Run on the
    /// main thread, as the canvas calls it, so `mainThreadBakeCount` tells whether the caller baked.
    @MainActor @Test func backgroundPolicyEvaluatesDirectlyAndBakesOffTheCallersThread() async throws {
        let uuid = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let profile = try LoadedProfile(data: ProfileFixture.xmp(name: "Background Bake", uuid: uuid, group: "Rendering",
            rgb: ProfileFixture.rgbTable(divisions: 5) { r, g, b in (r * 0.9, min(1, g * 1.1), b) }))
        let key = ProfileLUTCache.key(for: profile, percent: 80, options: .standard)
        let program = ProfileProgram(profile: profile.profile, percent: 80)
        let (width, height) = (1100, 1000)
        var pixels = Self.randomPremultiplied(width: width, height: height, seed: 7)
        var expected = pixels
        expected.withUnsafeMutableBufferPointer { buffer in
            program.withProgram { profile_apply_direct(buffer.baseAddress, width, height, width * 4, $0) }
        }
        // Called on the main thread, as the canvas calls it, so `mainThreadBakeCount` tells whether the caller baked.
        // Only the call: the pixels above are made off the main actor, which other suites time.
        pixels = await MainActor.run { [pixels] in
            var pixels = pixels
            pixels.withUnsafeMutableBufferPointer { buffer in
                ProfileRenderer.apply(pixels: buffer.baseAddress!, width: width, height: height, stride: width * 4,
                                      profile: profile, percent: 80, tables: .bakeInBackground)
            }
            return pixels
        }
        #expect(pixels == expected)
        // Nothing was baked on the caller's thread. (Whether the background bake is still running when the call returns
        // is timing: it starts before the direct pass and can finish first, so the cache isn't checked here.)
        #expect(ProfileLUTCache.mainThreadBakeCount(for: key) == 0)
        let deadline = Date().addingTimeInterval(20)
        while ProfileLUTCache.bakeCount(for: key) == 0, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(ProfileLUTCache.bakeCount(for: key) == 1)
        #expect(ProfileLUTCache.mainThreadBakeCount(for: key) == 0)
    }

    /// A background bake takes a free slot, or evicts a table only once it has gone `inUse` unused, so more visible
    /// (profile, amount) pairs than the cache holds don't rebake one another on every redraw.
    @Test func lruAdmitsABackgroundBakeOnlyPastTablesInUse() {
        var lru = ProfileLUTCache.LRU<Int>(capacity: 2)
        let keys = (0 ..< 2).map {
            ProfileLUTKey(digest: ProfileDigest(of: Data([UInt8($0)])), percent: 100, options: .standard, revision: 1)
        }
        let start = ContinuousClock.now
        func admits(after milliseconds: Int) -> Bool {
            lru.admitsBackgroundBake(at: start + .milliseconds(milliseconds), inUse: .seconds(1))
        }
        #expect(admits(after: 0))
        _ = lru.insert(0, for: keys[0], at: start)
        #expect(admits(after: 0))
        _ = lru.insert(1, for: keys[1], at: start)
        #expect(!admits(after: 500))
        #expect(admits(after: 2000))
        // Drawing with the oldest table keeps it; then the other one is the oldest, and it's been unused 2 s.
        _ = lru.value(for: keys[0], at: start + .milliseconds(1800))
        #expect(admits(after: 2000))
        _ = lru.value(for: keys[1], at: start + .milliseconds(1900))
        #expect(!admits(after: 2000))
    }

    /// Valid premultiplied RGBA: alpha from {0, 1, 17, 128, 254, 255}, each channel at most alpha.
    static func randomPremultiplied(width: Int, height: Int, seed: UInt32) -> [UInt8] {
        let alphas: [UInt8] = [0, 1, 17, 128, 254, 255]
        var random = LCG(seed: seed)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for pixel in 0 ..< width * height {
            let alpha = alphas[Int(random.next() % UInt32(alphas.count))]
            for channel in 0 ..< 3 { pixels[pixel * 4 + channel] = UInt8(random.next() % (UInt32(alpha) + 1)) }
            pixels[pixel * 4 + 3] = alpha
        }
        return pixels
    }

    struct LCG {
        var state: UInt32
        init(seed: UInt32) { state = seed }
        mutating func next() -> UInt32 {
            state = state &* 1_664_525 &+ 1_013_904_223
            return state >> 8
        }
        mutating func byte() -> UInt8 { UInt8(truncatingIfNeeded: next()) }
    }
}
