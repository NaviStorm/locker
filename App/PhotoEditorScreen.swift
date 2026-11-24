import CoreImage
import SwiftUI

struct PhotoEditorScreen: View {
    let store: VaultStore
    let item: ListedDocument
    let saved: (UUID, VaultLibrary) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var original: CGImage?
    @State private var preview: CGImage?
    @State private var edits = [PhotoEdit]()
    @State private var displayedEdits: [PhotoEdit]?
    @State private var cropping = false
    @State private var crop = CGRect.zero
    @State private var saving = false
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                if let preview {
                    Color.clear
                        .aspectRatio(CGFloat(preview.width) / CGFloat(preview.height), contentMode: .fit)
                        .overlay {
                            Image(decorative: preview, scale: 1).resizable()
                            if cropping { CropFrame(rect: $crop) }
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if problem == nil { ProgressView().frame(maxHeight: .infinity) }
                if let problem { Text(problem).foregroundStyle(.red).padding(.horizontal) }
                if saving { ProgressView("Enregistrement…") }
                if preview != nil {
                    if cropping {
                        Text("Déplacez le cadre ou faites glisser ses coins.").font(.callout)
                        HStack {
                            Button("Annuler le cadre") { cropping = false }
                            Button("Appliquer le cadre") { edits.append(.crop(crop)); cropping = false }
                        }.disabled(saving)
                    } else {
                        HStack(spacing: 10) {
                            editButton("Rotation à gauche", "rotate.left") { edits.append(.left) }
                            editButton("Rotation à droite", "rotate.right") { edits.append(.right) }
                            editButton("Miroir horizontal", "arrow.left.and.right") { edits.append(.horizontalMirror) }
                            editButton("Miroir vertical", "arrow.up.and.down") { edits.append(.verticalMirror) }
                            editButton("Recadrer", "crop") {
                                crop = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
                                cropping = true
                            }
                        }.disabled(displayedEdits != edits || saving)
                    }
                }
            }
            .padding(.bottom, 12)
            .navigationTitle("Modifier la photo")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }.disabled(saving)
                }
                ToolbarItem(placement: .automatic) {
                    editButton("Annuler la dernière retouche", "arrow.uturn.backward") { edits.removeLast() }
                        .disabled(edits.isEmpty || cropping || saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Enregistrer") { save() }.disabled((edits.isEmpty && !cropping) || saving || preview == nil)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 400, idealWidth: 680, minHeight: 320, idealHeight: 520)
        #endif
        .interactiveDismissDisabled(saving)
        .task(id: edits) {
            let pending = edits
            do {
                let base: CGImage
                if let original { base = original }
                else {
                    base = try await store.photoEditingPreview(item.id)
                    try Task.checkCancellation()
                    original = base
                }
                let result = pending.isEmpty ? base : try await Task.detached(priority: .userInitiated) {
                    try PhotoEdit.render(CIImage(cgImage: base), applying: pending)
                }.value
                try Task.checkCancellation()
                try store.gate.check()
                preview = result
                displayedEdits = pending
                problem = nil
            } catch { if !Task.isCancelled { problem = error.localizedDescription } }
        }
    }

    private func editButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: symbol) }
            .labelStyle(.iconOnly).buttonStyle(.bordered).help(title)
    }

    private func save() {
        guard !saving else { return }
        let final = edits + (cropping ? [.crop(crop)] : [])
        saving = true
        Task {
            do {
                let id = try await store.savePhotoEdits(final, to: item.id)
                let library = try await store.library()
                try store.gate.check()
                dismiss()
                saved(id, library)
            } catch { problem = error.localizedDescription; saving = false }
        }
    }
}

private struct CropFrame: View {
    @Binding var rect: CGRect
    @State private var start: CGRect?

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let frame = CGRect(x: rect.minX * size.width, y: rect.minY * size.height,
                               width: rect.width * size.width, height: rect.height * size.height)
            ZStack(alignment: .topLeading) {
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: size))
                    path.addRect(frame)
                }.fill(.black.opacity(0.5), style: FillStyle(eoFill: true)).allowsHitTesting(false)
                Rectangle().strokeBorder(.white, lineWidth: 2)
                    .frame(width: frame.width, height: frame.height)
                    .contentShape(Rectangle())
                    .gesture(drag(in: size, corner: nil))
                    .position(x: frame.midX, y: frame.midY)
                ForEach(0..<4) { index in
                    let corner = CGPoint(x: index % 2 == 0 ? 0 : 1, y: index < 2 ? 0 : 1)
                    Circle().fill(.white).frame(width: 12, height: 12).shadow(radius: 1)
                        .frame(width: 36, height: 36).contentShape(Rectangle())
                        .gesture(drag(in: size, corner: corner))
                        .position(x: corner.x == 0 ? frame.minX : frame.maxX,
                                  y: corner.y == 0 ? frame.minY : frame.maxY)
                }
            }
        }
    }

    private func drag(in size: CGSize, corner: CGPoint?) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                guard size.width > 0, size.height > 0 else { return }
                let base = start ?? rect
                start = base
                let dx = value.translation.width / size.width
                let dy = value.translation.height / size.height
                if let corner {
                    let minWidth = min(0.25, 28 / size.width), minHeight = min(0.25, 28 / size.height)
                    let left = corner.x == 0 ? min(base.maxX - minWidth, max(0, base.minX + dx)) : base.minX
                    let right = corner.x == 1 ? max(left + minWidth, min(1, base.maxX + dx)) : base.maxX
                    let top = corner.y == 0 ? min(base.maxY - minHeight, max(0, base.minY + dy)) : base.minY
                    let bottom = corner.y == 1 ? max(top + minHeight, min(1, base.maxY + dy)) : base.maxY
                    rect = CGRect(x: left, y: top, width: right - left, height: bottom - top)
                } else {
                    rect.origin = CGPoint(x: min(1 - base.width, max(0, base.minX + dx)),
                                          y: min(1 - base.height, max(0, base.minY + dy)))
                }
            }
            .onEnded { _ in start = nil }
    }
}
