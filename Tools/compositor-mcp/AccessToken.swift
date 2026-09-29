import Foundation

/// Compositor's MCP access token, which the bridge sends as `Authorization: Bearer <token>` on every POST.
///
/// The app keeps it in a file only its user can read (`~/Library/Application Support/Compositor/mcp/token`, 0600) and
/// names that file in endpoint.json (`token_file`, with `"auth": "bearer"`); `--token-file` names one directly. The
/// file is read again for every request, so a token regenerated in Settings is picked up at once. The token is never
/// logged.
enum AccessToken {
    /// Why the token can't be used, worded for the client's user.
    struct Problem: Error {
        let message: String
    }

    /// The longest token file read: a token is 43 characters.
    static let maxFileBytes = 4096

    /// The token in `file`. Refuses a file that isn't this user's own regular file, that other users could read or
    /// change (anything wider than 0600), or that doesn't hold a token: such a token may no longer be secret, or may
    /// not be Compositor's.
    static func read(from file: URL) throws -> String {
        let path = file.path
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else {
            let reason = String(cString: strerror(errno))
            throw Problem(message: "Compositor's access token can't be read from \(path) (\(reason)): restart Compositor's MCP server (turn it off and on in Compositor's Settings), which makes the file again")
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw Problem(message: "Compositor's access token can't be read from \(path): it isn't a file")
        }
        guard info.st_uid == getuid() else {
            throw Problem(message: "Compositor's access token file at \(path) belongs to another user, so it isn't used")
        }
        let mode = info.st_mode & 0o777
        guard mode & 0o077 == 0 else {
            throw Problem(message: "Compositor's access token file at \(path) is open to other users (mode \(String(mode, radix: 8))), so it isn't used: run chmod 600 on it, or restart Compositor's MCP server, which makes it owner-only again")
        }
        var bytes = [UInt8](repeating: 0, count: maxFileBytes)
        var count = 0
        while count < bytes.count {
            let read = bytes.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress! + count, $0.count - count) }
            if read < 0, errno == EINTR { continue }
            guard read > 0 else { break }
            count += read
        }
        let token = String(decoding: bytes[..<count], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard isWellFormed(token) else {
            throw Problem(message: "Compositor's access token file at \(path) doesn't hold a token: regenerate the token in Compositor's Settings")
        }
        return token
    }

    /// 43 base64url characters, the shape Compositor makes: nothing that could break out of an HTTP header.
    static func isWellFormed(_ token: String) -> Bool {
        token.utf8.count == 43 && token.utf8.allSatisfy { byte in
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "_"): true
            default: false
            }
        }
    }

    /// What the client sees when the server refuses the bridge's token (HTTP 401).
    static let refusedHint = "Compositor's access token changed or is missing; restart the client or re-copy the setup snippet"
}
