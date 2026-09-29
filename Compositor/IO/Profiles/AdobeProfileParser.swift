import Foundation

/// Reads a Lightroom or Camera Raw profile: the crs properties of an XMP file whose PresetType is Look.
nonisolated enum AdobeProfileParser {
    static let maximumFileBytes = 4 * 1024 * 1024

    static func profile(from data: Data, decodeTables: Bool = true) throws -> AdobeProfile {
        guard data.count <= maximumFileBytes else { throw ProfileError.tooLarge }
        let collector = XMPCollector()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false
        parser.delegate = collector
        guard parser.parse() else { throw ProfileError.malformed("XML") }
        guard collector.isCameraRaw else { throw ProfileError.notAProfile(presetType: nil) }

        let simple = collector.simple
        let presetType = simple["PresetType"]
        guard presetType == CameraRawPresetType.look.rawValue else { throw ProfileError.notAProfile(presetType: presetType) }
        guard let uuid = simple["UUID"], uuid.utf8.count == 32, uuid.utf8.allSatisfy(isHexDigit) else {
            throw ProfileError.malformed("UUID")
        }
        func text(_ key: String) -> String? {
            if let alternatives = collector.alternatives[key] { return preferred(alternatives) }
            return simple[key].flatMap { $0.isEmpty ? nil : $0 }
        }
        // A Name of only whitespace names nothing, as a missing one doesn't.
        guard let name = text("Name"), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProfileError.malformed("Name")
        }
        var rgbTableAmount = 1.0
        if let value = simple["RGBTableAmount"] {
            guard let amount = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)), amount.isFinite,
                  (0...2).contains(amount) else { throw ProfileError.malformed("RGBTableAmount") }
            rgbTableAmount = amount
        }

        var settings = ProfileDevelopSettings()
        settings.values = simple.filter { !isMetadata($0.key) }
        settings.structured = collector.structured.filter { !isMetadata($0) }
        for key in collector.alternatives.keys where !isMetadata(key) { settings.structured.insert(key) }
        for (key, items) in collector.sequences.sorted(by: { $0.key < $1.key }) where !isMetadata(key) {
            let points = items.map(curvePoint)
            guard !points.isEmpty, points.allSatisfy({ $0 != nil }) else {
                // Only a tone curve must be a curve; any other Seq of text is kept by name.
                guard !key.hasPrefix("ToneCurve") else { throw ProfileError.malformed(key) }
                settings.structured.insert(key)
                continue
            }
            let curve = points.compactMap { $0 }
            guard (2...256).contains(curve.count),
                  curve.allSatisfy({ (0...255).contains($0.x) && (0...255).contains($0.y) }),
                  zip(curve, curve.dropFirst()).allSatisfy({ $0.x < $1.x }) else { throw ProfileError.malformed(key) }
            settings.toneCurves[key] = curve
        }

        let lookFingerprint = simple["LookTable"].flatMap { $0.isEmpty ? nil : $0.uppercased() }
        let rgbFingerprint = simple["RGBTable"].flatMap { $0.isEmpty ? nil : $0.uppercased() }
        var lookTable: HueSatMap?
        var rgbTable: RGBTable?
        // A named table missing from the file is not an error here: usability reports it.
        if decodeTables {
            if let fingerprint = lookFingerprint, let text = collector.tables[fingerprint] {
                guard case .look(let table) = try AdobeTableCodec.decodeTable(fingerprint: fingerprint, text: text) else {
                    throw ProfileError.malformed("table kind")
                }
                lookTable = table
            }
            if let fingerprint = rgbFingerprint, let text = collector.tables[fingerprint] {
                guard case .rgb(let table) = try AdobeTableCodec.decodeTable(fingerprint: fingerprint, text: text) else {
                    throw ProfileError.malformed("table kind")
                }
                rgbTable = table
            }
        }

        var support: ProfileSupport = []
        for (key, option) in supportKeys where isTrue(simple[key]) { support.insert(option) }
        return AdobeProfile(
            presetType: .look, uuid: uuid.uppercased(), name: name, group: text("Group"), sortName: text("SortName"),
            shortName: text("ShortName"), summary: text("Description"), cluster: simple["Cluster"], version: simple["Version"],
            processVersion: simple["ProcessVersion"], copyright: text("Copyright"), support: support,
            cameraModelRestriction: simple["CameraModelRestriction"].flatMap { $0.isEmpty ? nil : $0 },
            cameraProfile: simple["CameraProfile"], requiresRGBTables: isTrue(simple["RequiresRGBTables"]),
            convertToGrayscale: isTrue(simple["ConvertToGrayscale"]), rgbTableAmount: rgbTableAmount,
            lookTableFingerprint: lookFingerprint, rgbTableFingerprint: rgbFingerprint, embeddedTables: Set(collector.tables.keys),
            tablesDecoded: decodeTables, lookTable: lookTable, rgbTable: rgbTable, settings: settings)
    }

    /// Keys that describe the profile rather than set anything, besides every `Table_*` and `Supports*` key.
    private static let metadataKeys: Set<String> = [
        "PresetType", "Cluster", "UUID", "RequiresRGBTables", "CameraModelRestriction", "Copyright", "ContactInfo",
        "Version", "ProcessVersion", "Name", "ShortName", "SortName", "Group", "Description", "LookTable", "RGBTable",
        "HasSettings", "ShowInPresets", "ShowInQuickActions", "CameraProfile", "CompatibleVersion",
    ]

    private static let supportKeys: [(String, ProfileSupport)] = [
        ("SupportsAmount", .amount), ("SupportsColor", .color), ("SupportsMonochrome", .monochrome),
        ("SupportsSceneReferred", .sceneReferred), ("SupportsOutputReferred", .outputReferred),
        ("SupportsHighDynamicRange", .highDynamicRange), ("SupportsNormalDynamicRange", .normalDynamicRange),
    ]

    private static func isMetadata(_ key: String) -> Bool {
        metadataKeys.contains(key) || key.hasPrefix("Table_") || key.hasPrefix("Supports")
    }

    private static func isTrue(_ value: String?) -> Bool { value?.lowercased() == "true" }

    private static func isHexDigit(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte) || (0x41...0x46).contains(byte) || (0x61...0x66).contains(byte)
    }

    /// en-US, then en, then x-default, then the first; empty strings count as absent.
    private static func preferred(_ alternatives: [(language: String, text: String)]) -> String? {
        let present = alternatives.filter { !$0.text.isEmpty }
        for language in ["en-us", "en", "x-default"] {
            if let match = present.first(where: { $0.language.lowercased() == language }) { return match.text }
        }
        return present.first?.text
    }

    /// "x, y" with integers; whitespace around each is allowed.
    private static func curvePoint(_ text: String) -> ProfileCurvePoint? {
        let parts = text.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let x = Int(parts[0].trimmingCharacters(in: .whitespacesAndNewlines)),
              let y = Int(parts[1].trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return ProfileCurvePoint(x: x, y: y)
    }
}

/// Collects the crs properties of the first rdf:Description directly under rdf:RDF. Namespace processing is off, so
/// prefixes are resolved here by URI from the xmlns declarations in scope: a file may use any prefix for crs.
private nonisolated final class XMPCollector: NSObject, XMLParserDelegate {
    static let cameraRawNamespace = "http://ns.adobe.com/camera-raw-settings/1.0/"
    static let rdfNamespace = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
    static let xmlNamespace = "http://www.w3.org/XML/1998/namespace"

    /// Whether the Description has any crs property.
    private(set) var isCameraRaw = false
    /// Simple values, from attributes or text-only elements, except tables.
    private(set) var simple: [String: String] = [:]
    /// rdf:Alt values whose items are text, with their xml:lang.
    private(set) var alternatives: [String: [(language: String, text: String)]] = [:]
    /// rdf:Seq values whose items are text.
    private(set) var sequences: [String: [String]] = [:]
    /// Everything else: structs, Bags, and containers of anything but text.
    private(set) var structured: Set<String> = []
    /// Table text keyed by its uppercase fingerprint.
    private(set) var tables: [String: String] = [:]

    private struct Name { let namespace: String?; let local: String }
    private struct Property {
        let name: String
        var isStructured: Bool
        var container: String?
        var items: [(language: String, text: String)] = []
        var itemLanguage = ""
        var itemIsText = true
    }

    private var scopes: [[String: String]] = []
    private var elements: [Name] = []
    /// The element depth of the Description being read.
    private var descriptionDepth: Int?
    private var finished = false
    private var property: Property?
    private var text = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        var declarations: [String: String] = [:]
        for (key, value) in attributeDict {
            if key == "xmlns" {
                declarations[""] = value
            } else if key.hasPrefix("xmlns:") {
                declarations[String(key.dropFirst(6))] = value
            }
        }
        scopes.append(declarations)
        let name = resolve(elementName, isAttribute: false)
        let parent = elements.last
        elements.append(name)
        guard !finished else { return }
        guard let top = descriptionDepth else {
            if name.namespace == Self.rdfNamespace, name.local == "Description",
               parent?.namespace == Self.rdfNamespace, parent?.local == "RDF" {
                descriptionDepth = elements.count
                for (key, value) in attributeDict {
                    let attribute = resolve(key, isAttribute: true)
                    if attribute.namespace == Self.cameraRawNamespace { record(attribute.local, value) }
                }
            }
            return
        }
        switch elements.count - top {
        case 1:
            text = ""
            guard name.namespace == Self.cameraRawNamespace else {
                property = nil
                return
            }
            isCameraRaw = true
            property = Property(name: name.local, isStructured: makesStruct(attributeDict))
        case 2:
            let isContainer = name.namespace == Self.rdfNamespace && ["Alt", "Seq", "Bag"].contains(name.local)
            if isContainer, property?.container == nil { property?.container = name.local } else { property?.isStructured = true }
        case 3:
            text = ""
            if name.namespace == Self.rdfNamespace, name.local == "li" {
                property?.itemLanguage = attributeDict["xml:lang"] ?? ""
                property?.itemIsText = !makesStruct(attributeDict)
            } else {
                property?.isStructured = true
            }
        default:
            property?.itemIsText = false
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard let top = descriptionDepth, !finished, property != nil else { return }
        let level = elements.count - top
        if level == 1 || level == 3 { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        defer {
            elements.removeLast()
            scopes.removeLast()
        }
        guard let top = descriptionDepth, !finished else { return }
        switch elements.count - top {
        case 0:
            finished = true
        case 1:
            if let property { finish(property) }
            property = nil
        case 3:
            guard var current = property, current.container != nil else { return }
            if current.itemIsText {
                current.items.append((language: current.itemLanguage, text: text))
            } else {
                current.isStructured = true
            }
            property = current
        default:
            break
        }
    }

    private func finish(_ property: Property) {
        guard !property.isStructured else {
            structured.insert(property.name)
            return
        }
        switch property.container {
        case nil: record(property.name, text)
        case "Alt": alternatives[property.name] = property.items
        case "Seq": sequences[property.name] = property.items.map(\.text)
        default: structured.insert(property.name)
        }
    }

    private func record(_ name: String, _ value: String) {
        isCameraRaw = true
        if name.hasPrefix("Table_") {
            tables[String(name.dropFirst(6)).uppercased()] = value
        } else {
            simple[name] = value
        }
    }

    /// rdf:parseType="Resource", or a qualifier-style attribute outside rdf and xml, makes a value a struct.
    private func makesStruct(_ attributes: [String: String]) -> Bool {
        attributes.contains { key, value in
            guard key != "xmlns", !key.hasPrefix("xmlns:") else { return false }
            let attribute = resolve(key, isAttribute: true)
            switch attribute.namespace {
            case Self.rdfNamespace: return attribute.local == "parseType" && value == "Resource"
            case Self.xmlNamespace, nil: return false
            default: return true
            }
        }
    }

    /// An unprefixed attribute has no namespace; an unprefixed element takes the default namespace.
    private func resolve(_ qualifiedName: String, isAttribute: Bool) -> Name {
        guard let colon = qualifiedName.firstIndex(of: ":") else {
            return Name(namespace: isAttribute ? nil : namespace(for: ""), local: qualifiedName)
        }
        return Name(namespace: namespace(for: String(qualifiedName[..<colon])),
                    local: String(qualifiedName[qualifiedName.index(after: colon)...]))
    }

    private func namespace(for prefix: String) -> String? {
        if prefix == "xml" { return Self.xmlNamespace }
        return scopes.reversed().lazy.compactMap { $0[prefix] }.first
    }
}
