import Foundation
import Darwin

enum VaultFiles {
    static func directory(_ url: URL) throws {
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        #if os(iOS)
        attributes[.protectionKey] = FileProtectionType.complete
        #endif
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: attributes)
    }

    static func newFile(_ url: URL) throws -> FileHandle {
        let fd = open(url.path, O_WRONLY | O_EXCL | O_CREAT | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        #if os(iOS)
        do {
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        #endif
        return handle
    }

    static func save(_ bytes: Data, to url: URL) throws {
        #if os(iOS)
        try bytes.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try bytes.write(to: url, options: .atomic)
        #endif
    }
}

/// Invalidated synchronously by the UI, including while the storage actor is busy.
final class SessionGate: @unchecked Sendable {
    private let mutex = NSLock()
    private var active = true
    func revoke() { mutex.withLock { active = false } }
    func close<T>(after operation: () throws -> T) throws -> T {
        try mutex.withLock {
            guard active else { throw VaultError.locked }
            let result = try operation()
            active = false
            return result
        }
    }

    func check() throws { try authorized {} }
    func authorized<T>(_ body: () throws -> T) throws -> T {
        try mutex.withLock {
            guard active else { throw VaultError.locked }
            return try body()
        }
    }
}
