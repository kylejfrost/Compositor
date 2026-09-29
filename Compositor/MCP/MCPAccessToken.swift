import Darwin
import Foundation
import Security
import Synchronization

/// The access token agents present to Compositor's MCP server as `Authorization: Bearer <token>`.
///
/// Why: loopback keeps out other computers, not other programs on this Mac. Other user accounts, and sandboxed apps
/// allowed outgoing connections, can reach 127.0.0.1 too, and would then act with Compositor's file access. The token
/// lives in a file only this user can read (`MCPSettings.tokenFileURL`, 0600 in a 0700 folder), so only this user's
/// own processes can present it; the `compositor-mcp` bridge reads it from there, finding the path in endpoint.json.
///
/// A token is 32 random bytes (`SecRandomCopyBytes`) in base64url without padding: 43 characters, safe in a header,
/// a shell word or a TOML string. It is kept across launches until regenerated; never logged or printed.
nonisolated enum MCPAccessToken {
    /// The characters of a token, 43 of them (`isWellFormed`).
    static let length = 43

    /// A new token.
    static func generate() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "Couldn't make an access token (random bytes unavailable, \(status))."])
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Whether `token` has the shape `generate` makes: 43 base64url characters.
    static func isWellFormed(_ token: String) -> Bool {
        token.utf8.count == length && token.utf8.allSatisfy { byte in
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "_"): true
            default: false
            }
        }
    }

    /// The token kept at `url`, made there first when the file is missing or doesn't hold one. Every call makes the
    /// folder owner-only (0700) and the file owner-only (0600), whatever they were.
    static func loadOrCreate(at url: URL) throws -> String {
        try secureFolder(for: url)
        if let data = try? Data(contentsOf: url),
           let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           isWellFormed(token) {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return token
        }
        return try regenerate(at: url)
    }

    /// Replaces the token at `url` with a new one and returns it. The file is swapped in whole (a reader sees the old
    /// token or the new one, never part of either) and is owner-only from the moment it exists.
    static func regenerate(at url: URL) throws -> String {
        try secureFolder(for: url)
        let token = try generate()
        try writeOwnerOnly(Data(token.utf8), to: url)
        return token
    }

    /// Whether the `Authorization` header value `authorization` presents `token` as a Bearer credential. The scheme is
    /// case-insensitive (RFC 9110); the token is compared in constant time.
    static func authorizes(_ authorization: String?, token: String) -> Bool {
        guard let authorization else { return false }
        let parts = authorization.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return false }
        let presented = parts[1].trimmingCharacters(in: .whitespaces)
        return constantTimeEquals(Array(presented.utf8), Array(token.utf8))
    }

    /// Whether `presented` equals `expected`, looking at every byte of `expected` whatever `presented` holds, so the
    /// time taken doesn't reveal how much of a guess was right.
    static func constantTimeEquals(_ presented: [UInt8], _ expected: [UInt8]) -> Bool {
        var difference: UInt8 = presented.count == expected.count ? 0 : 1
        for index in expected.indices {
            difference |= expected[index] ^ (index < presented.count ? presented[index] : 0)
        }
        return difference == 0
    }

    /// Creates the token's folder if needed (its parents as usual) and makes it owner-only.
    private static func secureFolder(for url: URL) throws {
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
    }

    /// Writes `data` to a new owner-only file beside `url`, then renames it over `url`.
    private static func writeOwnerOnly(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent)-\(UUID().uuidString)")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw posixError() }
        do {
            defer { close(descriptor) }
            try writeAll(data, to: descriptor)
            // 0600 whatever the umask made of it.
            guard fchmod(descriptor, 0o600) == 0, fsync(descriptor) == 0 else { throw posixError() }
        } catch {
            unlink(temporary.path)
            throw error
        }
        guard rename(temporary.path, url.path) == 0 else {
            let error = posixError()
            unlink(temporary.path)
            throw error
        }
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw posixError()
                }
                offset += count
            }
        }
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

/// What the listener checks each request's `Authorization` header against, before reading its body. Holds the token
/// while one is required, nil while any request may pass. The token changes while the server runs (Regenerate, the
/// Settings switch), and connections read it on the listener's queue, hence the lock.
nonisolated final class MCPAccessGate: Sendable {
    private let token = Mutex<String?>(nil)

    /// The token every request must present; nil lets every request through.
    var requiredToken: String? {
        get { token.withLock { $0 } }
        set { token.withLock { $0 = newValue } }
    }

    /// Whether a request carrying `authorization` (its `Authorization` header, if any) may be served.
    func permits(_ authorization: String?) -> Bool {
        guard let required = requiredToken else { return true }
        return MCPAccessToken.authorizes(authorization, token: required)
    }
}
