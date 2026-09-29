@testable import Compositor
import Foundation

/// Builds synthetic Lightroom and Camera Raw profiles for tests. Adobe's own profiles are never committed;
/// every table here comes from `AdobeTableCodec`'s encoder.
enum ProfileFixture {
    /// A complete Look profile. Tables are encoded with AdobeTableCodec.encodeTable and embedded as crs:Table_<fp>
    /// unless embedTables is false; `prefix` is the namespace prefix used for the crs namespace.
    static func xmp(name: String = "Test Look", uuid: String = "0123456789ABCDEF0123456789ABCDEF",
                    group: String? = "Tests", presetType: String? = "Look", outputReferred: Bool = true,
                    cameraModel: String? = nil, supportsAmount: Bool = true, grayscale: Bool = false,
                    rgbTableAmount: Double? = nil, look: HueSatMap? = nil, rgb: RGBTable? = nil,
                    embedTables: Bool = true, settings: [String: String] = [:],
                    curves: [String: [(Int, Int)]] = [:], elementForm: Bool = false, prefix: String = "crs",
                    nameXML: String? = nil, extraDescriptionXML: String = "", doctype: String = "") -> Data {
        var simple: [(String, String)] = []
        if let presetType { simple.append(("PresetType", presetType)) }
        simple.append(("UUID", uuid))
        simple.append(("SupportsAmount", flag(supportsAmount)))
        simple.append(("SupportsColor", "True"))
        simple.append(("SupportsNormalDynamicRange", "True"))
        simple.append(("SupportsSceneReferred", "True"))
        simple.append(("SupportsOutputReferred", flag(outputReferred)))
        if let cameraModel { simple.append(("CameraModelRestriction", cameraModel)) }
        if grayscale { simple.append(("ConvertToGrayscale", "True")) }
        if let rgbTableAmount { simple.append(("RGBTableAmount", String(rgbTableAmount))) }
        simple += settings.sorted { $0.key < $1.key }
        var tables: [(String, String)] = []
        for (key, table) in [("LookTable", look.map(AdobeTable.look)), ("RGBTable", rgb.map(AdobeTable.rgb))] {
            guard let table else { continue }
            let encoded = AdobeTableCodec.encodeTable(table)
            simple.append((key, encoded.fingerprint))
            if embedTables { tables.append(("Table_" + encoded.fingerprint, encoded.text)) }
        }
        simple += tables

        var description = "<rdf:Description rdf:about=\"\" xmlns:\(prefix)=\"http://ns.adobe.com/camera-raw-settings/1.0/\""
        var children = ""
        for (key, value) in simple {
            if elementForm {
                let text = key.hasPrefix("Table_") ? wrapped(value, every: 60) : escaped(value)
                children += "\n  <\(prefix):\(key)>\(text)</\(prefix):\(key)>"
            } else {
                description += "\n  \(prefix):\(key)=\"\(escaped(value))\""
            }
        }
        description += ">"
        children += "\n  " + (nameXML ?? localized("Name", name, prefix: prefix))
        if let group { children += "\n  " + localized("Group", group, prefix: prefix) }
        for (key, points) in curves.sorted(by: { $0.key < $1.key }) {
            let items = points.map { "<rdf:li>\($0.0), \($0.1)</rdf:li>" }.joined()
            children += "\n  <\(prefix):\(key)><rdf:Seq>\(items)</rdf:Seq></\(prefix):\(key)>"
        }
        children += extraDescriptionXML
        let xml = """
            \(doctype)<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
             \(description)\(children)
             </rdf:Description></rdf:RDF></x:xmpmeta>
            """
        return Data(xml.utf8)
    }

    static func hueSatMap(hue: Int, saturation: Int, value: Int, encoding: HueSatMap.Encoding = .linear,
                          amount: ClosedRange<Double> = 1...1,
                          _ entry: (_ v: Int, _ h: Int, _ s: Int) -> (Float, Float, Float) = { _, _, _ in (0, 1, 1) }) -> HueSatMap {
        var entries: [Float] = []
        entries.reserveCapacity(hue * saturation * value * 3)
        for v in 0 ..< value {
            for h in 0 ..< hue {
                for s in 0 ..< saturation {
                    let node = entry(v, h, s)
                    entries += [node.0, node.1, node.2]
                }
            }
        }
        return HueSatMap(hueDivisions: hue, saturationDivisions: saturation, valueDivisions: value, entries: entries,
                         encoding: encoding, minimumAmount: amount.lowerBound, maximumAmount: amount.upperBound)
    }

    /// Each node's coordinate is the SDK's identity value / 65535; the transform's result is clamped and quantized.
    static func rgbTable(divisions: Int, dimensions: Int = 3, primaries: RGBTable.Primaries = .sRGB,
                         gamma: RGBTable.Gamma = .sRGB, gamut: RGBTable.Gamut = .clip, amount: ClosedRange<Double> = 0...1,
                         _ transform: (_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) = { ($0, $1, $2) }) -> RGBTable {
        let nop = AdobeTableCodec.identityValues(divisions: divisions)
        func sample(_ x: Double) -> UInt16 { UInt16((min(max(x, 0), 1) * 65535).rounded()) }
        func node(_ r: Int, _ g: Int, _ b: Int) -> [UInt16] {
            let out = transform(Double(nop[r]) / 65535, Double(nop[g]) / 65535, Double(nop[b]) / 65535)
            return [sample(out.0), sample(out.1), sample(out.2)]
        }
        var samples: [UInt16] = []
        if dimensions == 3 {
            for r in 0 ..< divisions {
                for g in 0 ..< divisions {
                    for b in 0 ..< divisions { samples += node(r, g, b) }
                }
            }
        } else {
            for i in 0 ..< divisions { samples += node(i, i, i) }
        }
        return RGBTable(dimensions: dimensions, divisions: divisions, samples: samples, primaries: primaries, gamma: gamma,
                        gamut: gamut, minimumAmount: amount.lowerBound, maximumAmount: amount.upperBound)
    }

    private static func flag(_ value: Bool) -> String { value ? "True" : "False" }

    private static func escaped(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func wrapped(_ text: String, every width: Int) -> String {
        var lines: [Substring] = []
        var rest = Substring(text)
        while !rest.isEmpty {
            lines.append(rest.prefix(width))
            rest = rest.dropFirst(width)
        }
        return lines.joined(separator: "\n")
    }

    private static func localized(_ key: String, _ value: String, prefix: String) -> String {
        "<\(prefix):\(key)><rdf:Alt><rdf:li xml:lang=\"x-default\">\(escaped(value))</rdf:li></rdf:Alt></\(prefix):\(key)>"
    }
}
