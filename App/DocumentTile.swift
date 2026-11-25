import SwiftUI
import UniformTypeIdentifiers

struct DocumentTile: View {
    let item: ListedDocument
    let store: VaultStore?
    var showsFolder = false
    @State private var thumbnail: CGImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: 12)
                .fill(.background)
                .frame(height: 90)
                .overlay {
                    if let thumbnail {
                        GeometryReader { geometry in
                            Image(decorative: thumbnail, scale: 1).resizable().scaledToFill()
                                .frame(width: geometry.size.width, height: geometry.size.height)
                        }
                    } else { DocumentGlyph(name: item.labels.name) }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
            Text(item.labels.name).font(.callout.weight(.medium)).lineLimit(2, reservesSpace: true)
            if showsFolder && !item.labels.folder.isEmpty {
                Label(item.labels.folder, systemImage: "folder").font(.caption).lineLimit(1)
            }
            Text(item.size.formatted(.byteCount(style: .file))).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .task(id: item.labels.name) {
            thumbnail = nil
            guard let store, UTType(filenameExtension: (item.labels.name as NSString).pathExtension)?.conforms(to: .image) == true
            else { return }
            let result = try? await store.photoThumbnail(item.id)
            guard !Task.isCancelled, (try? store.gate.check()) != nil else { return }
            thumbnail = result
        }
        .onDisappear { thumbnail = nil }
    }
}
