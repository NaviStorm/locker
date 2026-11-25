import SwiftUI

struct VaultOverview: View {
    let title: String
    let provider: String
    let documents: [ListedDocument]
    let folderCount: Int?
    let open: (UUID) -> Void

    var body: some View {
        let recent = documents.sorted { ($0.created ?? .distantPast) > ($1.created ?? .distantPast) }.prefix(4)
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 14) {
                    VaultGlyph(symbol: folderCount == nil ? "folder.fill" : "lock.shield.fill")
                    Text(title).font(.system(.largeTitle, design: .rounded, weight: .bold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(provider).font(.callout).foregroundStyle(.secondary)
                    Divider()
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 20) { counts }
                        VStack(alignment: .leading, spacing: 6) { counts }
                    }
                    .font(.subheadline.weight(.medium))
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background, in: RoundedRectangle(cornerRadius: 20))
                if !recent.isEmpty {
                    Text("Documents récents").font(.title3.weight(.semibold))
                    VStack(spacing: 0) {
                        ForEach(recent) { item in
                            Button { open(item.id) } label: {
                                HStack(spacing: 12) {
                                    DocumentGlyph(name: item.labels.name)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(item.labels.name).font(.headline).lineLimit(2)
                                        Text(item.size.formatted(.byteCount(style: .file)))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.forward").font(.caption)
                                        .foregroundStyle(.secondary).accessibilityHidden(true)
                                }.padding(12).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            if item.id != recent.last?.id { Divider().padding(.leading, 60) }
                        }
                    }
                    .background(.background, in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .padding(20)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .background(Color.lockerCanvas)
    }

    @ViewBuilder private var counts: some View {
        Label(documents.count == 1 ? "1 document" : "\(documents.count) documents", systemImage: "doc")
        if let folderCount {
            Label(folderCount == 1 ? "1 dossier" : "\(folderCount) dossiers", systemImage: "folder")
        }
    }
}
