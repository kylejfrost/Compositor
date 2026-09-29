import CoreGraphics
import Dispatch
import Foundation
import simd
import Synchronization

// Lightroom and Camera Raw profiles on 8-bit sRGB pixels. Every possible colour is evaluated exactly through the
// C kernel in ProfilePixels.c: directly for small images, or once each into a 256³ table for large ones. Both paths
// give identical bytes. An interpolated colour cube is not accurate enough for Adobe's tables. The canvas never waits
// for a table: it evaluates directly until one baked off the main thread is ready (see `ProfileTablePolicy`).

/// Choices the DNG SDK leaves open, with the reference pipeline's answers as defaults.
nonisolated struct ProfileRenderOptions: Hashable, Sendable {
    /// Hypothesis U1: whether a fixed-amount look table (min = max = 1, as Adobe Color's) runs on rendered images.
    nonisolated enum FixedLookTables: Int, Hashable, Sendable { case full, scaledWithAmount, skipped }
    var fixedLookTables: FixedLookTables = .full
    static let standard = ProfileRenderOptions()
}

/// The amount each table stage runs at; nil when the stage doesn't run.
nonisolated struct ProfileStageAmounts: Equatable, Sendable {
    var look: Double?
    var rgb: Double?
}

/// The DNG SDK's colour spaces: each space's to-PCS matrix (XYZ D50) row-scaled so RGB white maps to PCS white.
nonisolated enum ProfileColorSpaces {
    /// XYZ of D50 at xy (0.3457, 0.3585).
    private static let pcsWhite = SIMD3<Double>(0.3457 / 0.3585, 1, (1 - 0.3457 - 0.3585) / 0.3585)

    static func matrixToPCS(_ primaries: RGBTable.Primaries) -> simd_double3x3 {
        let rows: [SIMD3<Double>] = switch primaries {
        case .sRGB: [SIMD3(0.4361, 0.3851, 0.1431), SIMD3(0.2225, 0.7169, 0.0606), SIMD3(0.0139, 0.0971, 0.7141)]
        case .adobeRGB: [SIMD3(0.6097, 0.2053, 0.1492), SIMD3(0.3111, 0.6257, 0.0632), SIMD3(0.0195, 0.0609, 0.7446)]
        case .proPhoto: [SIMD3(0.7977, 0.1352, 0.0313), SIMD3(0.2880, 0.7119, 0.0001), SIMD3(0, 0, 0.8249)]
        case .displayP3: [SIMD3(0.5151, 0.2920, 0.1571), SIMD3(0.2412, 0.6922, 0.0666), SIMD3(-0.0010, 0.0419, 0.7843)]
        case .rec2020: [SIMD3(0.6735, 0.1657, 0.1251), SIMD3(0.2791, 0.6753, 0.0456), SIMD3(-0.0019, 0.0300, 0.7971)]
        }
        return simd_double3x3(rows: (0 ..< 3).map { rows[$0] * (pcsWhite[$0] / rows[$0].sum()) })
    }

    static func matrix(from source: RGBTable.Primaries, to destination: RGBTable.Primaries) -> simd_double3x3 {
        matrixToPCS(destination).inverse * matrixToPCS(source)
    }

    /// Luminance in linear ProPhoto: the Y row of its to-PCS matrix.
    static let grayWeights: SIMD3<Double> = {
        let matrix = matrixToPCS(.proPhoto)
        return SIMD3(matrix[0][1], matrix[1][1], matrix[2][1])
    }()
}

/// A smooth curve through points, with the DNG SDK's slopes (`dng_spline_solver`), as Camera Raw draws point curves.
nonisolated struct ProfileSpline: Equatable, Sendable {
    private let x: [Double]
    private let y: [Double]
    let slopes: [Double]

    /// At least two points, x strictly increasing.
    init(x: [Double], y: [Double]) {
        precondition(x.count >= 2 && x.count == y.count, "A spline needs at least two points")
        self.x = x
        self.y = y
        slopes = Self.slopes(x, y)
    }

    private static func slopes(_ x: [Double], _ y: [Double]) -> [Double] {
        let n = x.count
        var s = [Double](repeating: 0, count: n)
        var a = x[1] - x[0], b = (y[1] - y[0]) / a
        s[0] = b
        for j in stride(from: 2, to: n, by: 1) {
            let c = x[j] - x[j - 1], d = (y[j] - y[j - 1]) / c
            s[j - 1] = (b * c + d * a) / (a + c)
            a = c
            b = d
        }
        s[n - 1] = 2 * b - s[n - 2]
        s[0] = 2 * s[0] - s[1]
        guard n > 2 else { return s }
        // Smooth the estimates by solving the tridiagonal system for continuous second derivatives.
        var e = [Double](repeating: 0, count: n), f = e, g = e
        f[0] = 0.5
        e[n - 1] = 0.5
        g[0] = 0.75 * (s[0] + s[1])
        g[n - 1] = 0.75 * (s[n - 2] + s[n - 1])
        for j in 1 ..< n - 1 {
            let span = (x[j + 1] - x[j - 1]) * 2
            e[j] = (x[j + 1] - x[j]) / span
            f[j] = (x[j] - x[j - 1]) / span
            g[j] = 1.5 * s[j]
        }
        for j in 1 ..< n {
            let pivot = 1 - f[j - 1] * e[j]
            if j != n - 1 { f[j] /= pivot }
            g[j] = (g[j] - g[j - 1] * e[j]) / pivot
        }
        for j in stride(from: n - 2, through: 0, by: -1) { g[j] -= f[j] * g[j + 1] }
        return g
    }

    /// The Hermite segment from (x0, y0) with slope s0 to (x1, y1) with slope s1.
    private static func segment(_ value: Double, _ x0: Double, _ y0: Double, _ s0: Double,
                        _ x1: Double, _ y1: Double, _ s1: Double) -> Double {
        let a = x1 - x0, b = (value - x0) / a, c = (x1 - value) / a
        return (y0 * (2 - c + b) + s0 * a * b) * c * c + (y1 * (2 - b + c) - s1 * a * c) * b * b
    }

    func callAsFunction(_ value: Double) -> Double {
        let last = x.count - 1
        if value <= x[0] { return y[0] }
        if value >= x[last] { return y[last] }
        // The first point at or after value; it lies in 1…last.
        var low = 1, high = last
        while low < high {
            let middle = (low + high) / 2
            if x[middle] >= value { high = middle } else { low = middle + 1 }
        }
        return Self.segment(value, x[low - 1], y[low - 1], slopes[low - 1], x[low], y[low], slopes[low])
    }
}

/// A profile's point curve (crs:ToneCurvePV2012 and its channel curves) on 0…1.
nonisolated struct ProfileToneCurve: Equatable, Sendable {
    private let spline: ProfileSpline

    /// nil for no points or the identity [(0, 0), (255, 255)], which leave colours alone.
    init?(points: [ProfileCurvePoint]) {
        guard points.count >= 2, points != [ProfileCurvePoint(x: 0, y: 0), ProfileCurvePoint(x: 255, y: 255)] else { return nil }
        spline = ProfileSpline(x: points.map { Double($0.x) / 255 }, y: points.map { Double($0.y) / 255 })
    }

    func callAsFunction(_ x: Double) -> Double { spline(x) }

    /// The curve at i / (count − 1) for each i, as the C kernel interpolates it.
    func samples(count: Int = Int(PROFILE_CURVE_SAMPLES)) -> [Float] {
        (0 ..< count).map { Float(spline(Double($0) / Double(count - 1))) }
    }
}

/// A profile compiled for the C kernel at one set of stage amounts. It owns the kernel's buffers and never changes.
nonisolated final class ProfileProgram: @unchecked Sendable {
    let amounts: ProfileStageAmounts
    private let look: UnsafeMutableBufferPointer<Float>?
    private let curves: UnsafeMutableBufferPointer<Float>?
    private let rgb: UnsafeMutableBufferPointer<Float>?
    private let program: profile_program

    init(profile: AdobeProfile, amounts: ProfileStageAmounts) {
        self.amounts = amounts
        var program = profile_program()
        Self.store(Self.rowMajor(ProfileColorSpaces.matrix(from: .sRGB, to: .proPhoto)), in: &program.sRGBToProPhoto)
        Self.store(Self.rowMajor(ProfileColorSpaces.matrix(from: .proPhoto, to: .sRGB)), in: &program.proPhotoToSRGB)
        let gray = ProfileColorSpaces.grayWeights
        Self.store([gray.x, gray.y, gray.z], in: &program.grayWeights)
        program.grayscale = profile.convertToGrayscale ? 1 : 0

        // The look amount scales each delta before the lookup (hypothesis H-LA).
        if let table = profile.lookTable, let amount = amounts.look, Self.isComplete(table) {
            let buffer = UnsafeMutableBufferPointer<Float>.allocate(capacity: table.entries.count)
            for node in stride(from: 0, to: table.entries.count, by: 3) {
                let hue = Double(table.entries[node]), saturation = Double(table.entries[node + 1])
                let value = Double(table.entries[node + 2])
                buffer[node] = Float(hue * amount)
                buffer[node + 1] = Float(1 + (saturation - 1) * amount)
                buffer[node + 2] = Float(1 + (value - 1) * amount)
            }
            look = buffer
            program.look = UnsafePointer(buffer.baseAddress)
            program.hueDivisions = UInt32(table.hueDivisions)
            program.saturationDivisions = UInt32(table.saturationDivisions)
            program.valueDivisions = UInt32(table.valueDivisions)
            program.lookEncoding = Int32(table.encoding.rawValue)
        } else {
            look = nil
        }

        let names = ["ToneCurvePV2012", "ToneCurvePV2012Red", "ToneCurvePV2012Green", "ToneCurvePV2012Blue"]
        let toneCurves = names.map { profile.settings.toneCurves[$0].flatMap(ProfileToneCurve.init(points:)) }
        if toneCurves.contains(where: { $0 != nil }) {
            let count = Int(PROFILE_CURVE_SAMPLES)
            let identity = (0 ..< count).map { Float(Double($0) / Double(count - 1)) }
            let buffer = UnsafeMutableBufferPointer<Float>.allocate(capacity: count * 4)
            for (index, curve) in toneCurves.enumerated() {
                let samples = curve?.samples(count: count) ?? identity
                _ = UnsafeMutableBufferPointer(rebasing: buffer[index * count ..< (index + 1) * count])
                    .initialize(fromContentsOf: samples)
                if curve != nil { program.curveMask |= Int32(1 << index) }
            }
            curves = buffer
            program.curves = UnsafePointer(buffer.baseAddress)
        } else {
            curves = nil
        }

        if let table = profile.rgbTable, let amount = amounts.rgb, Self.isComplete(table) {
            let buffer = UnsafeMutableBufferPointer<Float>.allocate(capacity: table.samples.count)
            for (index, sample) in table.samples.enumerated() { buffer[index] = Float(Double(sample) / 65535) }
            rgb = buffer
            program.rgb = UnsafePointer(buffer.baseAddress)
            program.rgbDimensions = UInt32(table.dimensions)
            program.rgbDivisions = UInt32(table.divisions)
            program.rgbPrimaries = Int32(table.primaries.rawValue)
            program.rgbGamma = Int32(table.gamma.rawValue)
            program.rgbGamut = Int32(table.gamut.rawValue)
            program.rgbAmount = amount
            Self.store(Self.rowMajor(ProfileColorSpaces.matrix(from: .proPhoto, to: table.primaries)),
                       in: &program.proPhotoToTable)
            Self.store(Self.rowMajor(ProfileColorSpaces.matrix(from: table.primaries, to: .proPhoto)),
                       in: &program.tableToProPhoto)
        } else {
            rgb = nil
        }
        self.program = program
    }

    convenience init(profile: AdobeProfile, percent: Int, options: ProfileRenderOptions = .standard) {
        self.init(profile: profile, amounts: ProfileRenderer.amounts(for: profile, percent: percent, options: options))
    }

    deinit {
        look?.deallocate()
        curves?.deallocate()
        rgb?.deallocate()
    }

    func withProgram<R>(_ body: (UnsafePointer<profile_program>) throws -> R) rethrows -> R {
        try withUnsafePointer(to: program, body)
    }

    /// Encoded sRGB (0–1) in and out, unrounded.
    func evaluate(_ srgb: SIMD3<Double>) -> SIMD3<Double> {
        var input = (srgb.x, srgb.y, srgb.z), output = (0.0, 0.0, 0.0)
        withProgram { program in
            Self.withElements(&input) { input in Self.withElements(&output) { profile_evaluate(program, input, $0) } }
        }
        return SIMD3(output.0, output.1, output.2)
    }

    func evaluate(byte: SIMD3<UInt8>) -> SIMD3<UInt8> {
        var input = (byte.x, byte.y, byte.z), output: (UInt8, UInt8, UInt8) = (0, 0, 0)
        withProgram { program in
            Self.withElements(&input) { input in Self.withElements(&output) { profile_evaluate_byte(program, input, $0) } }
        }
        return SIMD3(output.0, output.1, output.2)
    }

    /// The look stage alone, on linear ProPhoto; unchanged when the stage doesn't run.
    func hueSatMap(_ proPhoto: SIMD3<Double>) -> SIMD3<Double> {
        var rgb = (proPhoto.x, proPhoto.y, proPhoto.z)
        withProgram { program in Self.withElements(&rgb) { profile_hue_sat_map(program, $0) } }
        return SIMD3(rgb.0, rgb.1, rgb.2)
    }

    /// The RGB table stage alone, on linear ProPhoto; unchanged when the stage doesn't run.
    func rgbTable(_ proPhoto: SIMD3<Double>) -> SIMD3<Double> {
        var rgb = (proPhoto.x, proPhoto.y, proPhoto.z)
        withProgram { program in Self.withElements(&rgb) { profile_rgb_table(program, $0) } }
        return SIMD3(rgb.0, rgb.1, rgb.2)
    }

    /// Whether a table's buffers are the size its divisions say, so the kernel can't read past them. Parsed tables
    /// always are.
    private static func isComplete(_ table: HueSatMap) -> Bool {
        table.hueDivisions >= 1 && table.saturationDivisions >= 2 && table.valueDivisions >= 1
            && table.entries.count == table.hueDivisions * table.saturationDivisions * table.valueDivisions * 3
    }

    private static func isComplete(_ table: RGBTable) -> Bool {
        guard table.divisions >= 2 else { return false }
        switch table.dimensions {
        case 1: return table.samples.count == table.divisions * 3
        case 3: return table.samples.count == table.divisions * table.divisions * table.divisions * 3
        default: return false
        }
    }

    /// Row-major, as the C kernel stores matrices (simd matrices are column-major).
    private static func rowMajor(_ matrix: simd_double3x3) -> [Double] {
        (0 ..< 3).flatMap { row in (0 ..< 3).map { column in matrix[column][row] } }
    }

    /// Writes doubles into an imported C array (a homogeneous tuple).
    private static func store<Tuple>(_ values: [Double], in tuple: inout Tuple) {
        withUnsafeMutableBytes(of: &tuple) { bytes in
            precondition(bytes.count == values.count * MemoryLayout<Double>.stride)
            for (index, value) in values.enumerated() {
                bytes.storeBytes(of: value, toByteOffset: index * MemoryLayout<Double>.stride, as: Double.self)
            }
        }
    }

    private static func withElements<Element, R>(_ triple: inout (Element, Element, Element),
                                                 _ body: (UnsafeMutablePointer<Element>) -> R) -> R {
        withUnsafeMutablePointer(to: &triple) { $0.withMemoryRebound(to: Element.self, capacity: 3, body) }
    }
}

/// The profile's result for every opaque 8-bit colour: 256³ RGB entries, 48 MiB.
nonisolated final class ProfileLUT: @unchecked Sendable {
    static let byteCount = 256 * 256 * 256 * 3
    /// Entry ((r·256 + g)·256 + b)·3. Freed in deinit.
    let bytes: UnsafeMutableBufferPointer<UInt8>

    private init() {
        bytes = .allocate(capacity: Self.byteCount)
    }

    deinit { bytes.deallocate() }

    /// Evaluates every colour, one red plane per concurrent iteration.
    static func bake(_ program: ProfileProgram) -> ProfileLUT {
        let lut = ProfileLUT()
        guard let base = lut.bytes.baseAddress else { return lut }
        program.withProgram { compiled in
            // Each iteration writes its own red plane, and the program is only read.
            nonisolated(unsafe) let compiled = compiled, base = base
            DispatchQueue.concurrentPerform(iterations: 256) { red in profile_bake_lut(compiled, Int32(red), 1, base) }
        }
        return lut
    }

    subscript(r: UInt8, g: UInt8, b: UInt8) -> SIMD3<UInt8> {
        let index = (Int(r) << 16 | Int(g) << 8 | Int(b)) * 3
        return SIMD3(bytes[index], bytes[index + 1], bytes[index + 2])
    }
}

/// What `ProfileRenderer.apply` does with an image over `ProfileRenderer.directPixelLimit` pixels whose table isn't
/// baked yet.
nonisolated enum ProfileTablePolicy: Sendable {
    /// Bakes the table first, blocking the caller: exports and renders off the main thread, where one bake is cheaper
    /// than evaluating a large image pixel by pixel.
    case bakeNow
    /// Never waits for a bake: evaluates every pixel directly (the same bytes the table gives) and bakes the table off
    /// the caller's thread for later draws. The canvas draws with this on the main thread.
    case bakeInBackground
}

nonisolated struct ProfileLUTKey: Hashable, Sendable {
    let digest: ProfileDigest
    let percent: Int
    let options: ProfileRenderOptions
    let revision: Int
}

/// Baked tables (LRU, 4 × 48 MiB) and compiled programs (LRU, 16), shared by every document. A table is baked once
/// however many callers ask for it at the same time.
nonisolated enum ProfileLUTCache {
    static let capacity = 4
    private static let programCapacity = 16

    /// A bake in progress: later requesters wait on the group, then read the table.
    private final class Bake: @unchecked Sendable {
        let group = DispatchGroup()
        /// Written before the group is left, read only after waiting on it.
        var lut: ProfileLUT?
    }

    /// Internal only for tests.
    struct LRU<Value> {
        let capacity: Int
        /// Least recently used first, each with when it was last used.
        var entries: [(key: ProfileLUTKey, value: Value, used: ContinuousClock.Instant)] = []

        mutating func value(for key: ProfileLUTKey, at now: ContinuousClock.Instant = .now) -> Value? {
            guard let index = entries.firstIndex(where: { $0.key == key }) else { return nil }
            var entry = entries.remove(at: index)
            entry.used = now
            entries.append(entry)
            return entry.value
        }

        /// Returns what it replaced or evicted, for the caller to release once it has left the cache's lock.
        mutating func insert(_ value: Value, for key: ProfileLUTKey, at now: ContinuousClock.Instant = .now) -> [Value] {
            var removed: [Value] = []
            if let index = entries.firstIndex(where: { $0.key == key }) { removed.append(entries.remove(at: index).value) }
            entries.append((key, value, now))
            if entries.count > capacity {
                removed += entries.prefix(entries.count - capacity).map(\.value)
                entries.removeFirst(entries.count - capacity)
            }
            return removed
        }

        func contains(_ key: ProfileLUTKey) -> Bool { entries.contains { $0.key == key } }

        /// Whether one more entry would evict nothing used within `inUse` of `now`: there is room, or the least
        /// recently used entry has gone that long unused.
        func admitsBackgroundBake(at now: ContinuousClock.Instant, inUse: Duration) -> Bool {
            guard entries.count >= capacity, let oldest = entries.first else { return true }
            return now - oldest.used >= inUse
        }
    }

    /// How recently a table must have been drawn with to count as in use: a background bake never evicts one, so
    /// more visible (profile, amount) pairs than the cache holds don't rebake one another on every redraw; the pairs
    /// that don't fit are evaluated directly instead.
    static let inUseInterval: Duration = .seconds(1)

    private struct State {
        var luts = LRU<ProfileLUT>(capacity: ProfileLUTCache.capacity)
        var programs = LRU<ProfileProgram>(capacity: ProfileLUTCache.programCapacity)
        var bakes: [ProfileLUTKey: Bake] = [:]
        var bakeCounts: [ProfileLUTKey: Int] = [:]
        var mainThreadBakeCounts: [ProfileLUTKey: Int] = [:]
    }

    private static let state = Mutex(State())

    /// A profile without Amount renders the same at every percent, so it has one key.
    static func key(for profile: LoadedProfile, percent: Int, options: ProfileRenderOptions) -> ProfileLUTKey {
        ProfileLUTKey(digest: profile.digest, percent: profile.profile.support.contains(.amount) ? percent : 100,
                      options: options, revision: ProfileRenderer.revision)
    }

    static func cached(_ key: ProfileLUTKey) -> ProfileLUT? {
        state.withLock { $0.luts.value(for: key) }
    }

    /// The cached table, or one baked now (in parallel, blocking the caller); concurrent requests share one bake.
    static func lut(for profile: LoadedProfile, percent: Int, options: ProfileRenderOptions = .standard) -> ProfileLUT {
        let key = key(for: profile, percent: percent, options: options)
        enum Step { case cached(ProfileLUT), wait(Bake), bake(Bake) }
        let step: Step = state.withLock { state in
            if let lut = state.luts.value(for: key) { return .cached(lut) }
            if let bake = state.bakes[key] { return .wait(bake) }
            let bake = Bake()
            bake.group.enter()
            state.bakes[key] = bake
            return .bake(bake)
        }
        switch step {
        case .cached(let lut):
            return lut
        case .wait(let bake):
            bake.group.wait()
            guard let lut = bake.lut else { preconditionFailure("A finished bake has its table") }
            return lut
        case .bake(let bake):
            let lut = ProfileLUT.bake(program(for: profile, percent: percent, options: options))
            bake.lut = lut
            let onMain = Thread.isMainThread
            // The evicted table (48 MiB) is returned so it is freed after the lock is released, not under it.
            _ = state.withLock { state in
                state.bakes[key] = nil
                state.bakeCounts[key, default: 0] += 1
                if onMain { state.mainThreadBakeCounts[key, default: 0] += 1 }
                return state.luts.insert(lut, for: key)
            }
            bake.group.leave()
            return lut
        }
    }

    /// Bakes off the caller's thread, for a preview that is about to need the table.
    static func prebake(_ profile: LoadedProfile, percent: Int, options: ProfileRenderOptions = .standard) async {
        _ = await Task.detached(priority: .userInitiated) { lut(for: profile, percent: percent, options: options) }.value
    }

    /// Starts baking the table off the caller's thread and returns at once, unless it is cached or already baking, or
    /// making room would evict a table used within `inUseInterval`. Returns whether a bake started.
    @discardableResult
    static func bakeInBackground(_ profile: LoadedProfile, percent: Int, options: ProfileRenderOptions = .standard) -> Bool {
        let key = key(for: profile, percent: percent, options: options)
        let starts = state.withLock { state in
            !state.luts.contains(key) && state.bakes[key] == nil
                && state.luts.admitsBackgroundBake(at: .now, inUse: inUseInterval)
        }
        guard starts else { return false }
        // `lut` shares a bake another caller starts meanwhile.
        DispatchQueue.global(qos: .userInitiated).async { _ = lut(for: profile, percent: percent, options: options) }
        return true
    }

    static func program(for profile: LoadedProfile, percent: Int, options: ProfileRenderOptions = .standard) -> ProfileProgram {
        let key = key(for: profile, percent: percent, options: options)
        if let program = state.withLock({ $0.programs.value(for: key) }) { return program }
        let program = ProfileProgram(profile: profile.profile, percent: key.percent, options: options)
        // What the insert evicts is returned so it is freed after the lock is released.
        let (kept, _) = state.withLock { state -> (ProfileProgram, [ProfileProgram]) in
            if let existing = state.programs.value(for: key) { return (existing, []) }
            return (program, state.programs.insert(program, for: key))
        }
        return kept
    }

    /// Empties both caches (tests). Bakes in progress still finish and are cached.
    static func removeAll() {
        state.withLock { state in
            state.luts.entries.removeAll()
            state.programs.entries.removeAll()
        }
    }

    /// Bakes of `key` completed since launch (tests).
    static func bakeCount(for key: ProfileLUTKey) -> Int { state.withLock { $0.bakeCounts[key] ?? 0 } }

    /// Bakes of `key` that ran on the main thread since launch (tests: the canvas must never wait for one).
    static func mainThreadBakeCount(for key: ProfileLUTKey) -> Int { state.withLock { $0.mainThreadBakeCounts[key] ?? 0 } }
}

nonisolated enum ProfileRenderer {
    /// Part of every cache key: bump it when rendering changes.
    static let revision = 1
    /// Images up to this many pixels are evaluated directly unless a table is already baked.
    static let directPixelLimit = 1 << 20
    private static let bandRows = 64

    /// The SDK's table amount: `Round_int32(value × 100) × 0.01`, pinned to the table's range.
    static func sdkAmount(_ value: Double, _ minimum: Double, _ maximum: Double) -> Double {
        let hundredths = value * 100
        let rounded = hundredths > 0 ? (hundredths + 0.5).rounded(.towardZero) : (hundredths - 0.5).rounded(.towardZero)
        return min(max(rounded * 0.01, minimum), maximum)
    }

    /// Each stage's amount at a profile's Amount percentage (100 = as designed); a profile without Amount renders at
    /// 100 whatever the percentage (hypotheses H-AM and U1).
    static func amounts(for profile: AdobeProfile, percent: Int,
                        options: ProfileRenderOptions = .standard) -> ProfileStageAmounts {
        let amount = profile.support.contains(.amount) ? Double(percent) / 100 : 1
        let rgb = profile.rgbTable.map { sdkAmount(profile.rgbTableAmount * amount, $0.minimumAmount, $0.maximumAmount) }
        var look: Double?
        if let table = profile.lookTable {
            if table.isFixedAmount {
                switch options.fixedLookTables {
                case .full: look = 1
                case .scaledWithAmount: look = sdkAmount(amount, 0, 1)
                case .skipped: look = nil
                }
            } else {
                look = sdkAmount(amount, table.minimumAmount, table.maximumAmount)
            }
        }
        return ProfileStageAmounts(look: look, rgb: rgb)
    }

    /// Premultiplied RGBA8 in place; LUT when cached, direct when ≤ directPixelLimit pixels, else as `tables` says.
    static func apply(pixels: UnsafeMutablePointer<UInt8>, width: Int, height: Int, stride: Int,
                      profile: LoadedProfile, percent: Int, options: ProfileRenderOptions = .standard,
                      tables: ProfileTablePolicy = .bakeNow) {
        guard width > 0, height > 0 else { return }
        let key = ProfileLUTCache.key(for: profile, percent: percent, options: options)
        if let lut = ProfileLUTCache.cached(key) {
            apply(lut, to: pixels, width: width, height: height, stride: stride)
        } else if width * height <= directPixelLimit || tables == .bakeInBackground {
            if width * height > directPixelLimit {
                ProfileLUTCache.bakeInBackground(profile, percent: percent, options: options)
            }
            ProfileLUTCache.program(for: profile, percent: percent, options: options).withProgram { program in
                inBands(height: height) { first, rows in
                    profile_apply_direct(pixels + first * stride, width, rows, stride, program)
                }
            }
        } else {
            apply(ProfileLUTCache.lut(for: profile, percent: percent, options: options), to: pixels, width: width,
                  height: height, stride: stride)
        }
    }

    static func apply(_ image: CGImage, profile: LoadedProfile, percent: Int,
                      options: ProfileRenderOptions = .standard, tables: ProfileTablePolicy = .bakeNow) throws -> CGImage {
        try ImageAdjustmentPixels.run(image) { pixels, width, height, stride in
            apply(pixels: pixels, width: width, height: height, stride: stride, profile: profile, percent: percent,
                  options: options, tables: tables)
        }
    }

    private static func apply(_ lut: ProfileLUT, to pixels: UnsafeMutablePointer<UInt8>, width: Int, height: Int,
                              stride: Int) {
        let table = UnsafePointer(lut.bytes.baseAddress)
        inBands(height: height) { first, rows in profile_apply_lut(pixels + first * stride, width, rows, stride, table) }
    }

    /// Runs body over bands of 64 rows concurrently: (first row, row count).
    private static func inBands(height: Int, _ body: (Int, Int) -> Void) {
        DispatchQueue.concurrentPerform(iterations: (height + bandRows - 1) / bandRows) { band in
            let first = band * bandRows
            body(first, min(bandRows, height - first))
        }
    }
}
