import Foundation
import UniformTypeIdentifiers

extension ShareInbox.Writer {
    func receive(_ provider: NSItemProvider) async throws -> ShareInbox.Item {
        let types = provider.registeredTypeIdentifiers.compactMap { UTType($0) }
        if types.contains(.fileURL) {
            return try await withCheckedThrowingContinuation { continuation in
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                    do {
                        let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                        guard let url, url.isFileURL else { throw error ?? ShareIssue.invalid }
                        continuation.resume(returning: try receiveFile(url, name: url.lastPathComponent))
                    } catch { continuation.resume(throwing: error) }
                }
            }
        }
        if let type = types.first(where: { $0.conforms(to: .data) && !$0.conforms(to: .url) }) {
            let suggestedName = provider.suggestedName
            return try await withCheckedThrowingContinuation { continuation in
                provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
                    do {
                        guard let url else { throw error ?? ShareIssue.invalid }
                        var name = suggestedName ?? url.lastPathComponent
                        if (name as NSString).pathExtension.isEmpty, let ext = type.preferredFilenameExtension {
                            name += "." + ext
                        }
                        // The provider owns this URL only for the duration of its callback.
                        continuation.resume(returning: try receiveFile(url, name: name))
                    } catch { continuation.resume(throwing: error) }
                }
            }
        }
        if types.contains(where: { $0.conforms(to: .url) }),
           let url = try await loadItem(provider, type: .url) as? URL {
            if url.isFileURL { return try receiveFile(url, name: url.lastPathComponent) }
            var bytes = Data(url.absoluteString.utf8)
            return try store(name: "Lien.txt") { defer { bytes.removeAll() }; return bytes }
        }
        throw ShareIssue.invalid
    }

    private func loadItem(_ provider: NSItemProvider, type: UTType) async throws -> NSSecureCoding? {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type.identifier, options: nil) { item, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: item) }
            }
        }
    }

    private func receiveFile(_ url: URL, name: String) throws -> ShareInbox.Item {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let basename = (name as NSString).lastPathComponent
        return try store(name: basename.isEmpty ? "Document" : basename) {
            try file.read(upToCount: ShareInbox.chunkSize) ?? Data()
        }
    }
}
