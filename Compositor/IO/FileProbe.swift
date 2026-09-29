import CoreGraphics
import Foundation

/// What opening and importing find out about a file before reading it (whether it's a Photoshop file, a raw photo's
/// size and white balance), and a developed photo's thumbnail, off the main actor. Each probe reads the file, and a
/// cloud-only file (iCloud Drive, Google Drive) downloads in full first, which must not freeze the window or an
/// agent's other calls for the length of the download.
nonisolated enum FileProbe {
    /// Whether the file starts with Photoshop's signature.
    @concurrent static func isPhotoshop(_ url: URL) async -> Bool { PSDReader.matches(url) }

    /// A raw photo's pixel size, from its metadata.
    @concurrent static func rawPixelSize(_ url: URL) async -> (width: Int, height: Int)? { RawImporter.pixelSize(url) }

    /// A raw photo's own white balance (Core Image parses the raw file).
    @concurrent static func rawAsShot(_ url: URL) async -> RawDevelopSettings? { RawImporter.asShot(url) }

    /// A developed photo's Layers-panel thumbnail: a downsample of the full frame.
    @concurrent static func thumbnail(of image: CGImage) async throws -> CGImage { try PixelAdjust.thumbnail(of: image) }
}
