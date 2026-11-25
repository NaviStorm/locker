import SwiftUI

/// The offset is measured from the centre of the viewing area, in screen points.
struct PhotoViewport: Equatable {
    var scale: CGFloat = 1
    var offset: CGSize = .zero

    func imageSize(_ photo: CGSize, in view: CGSize) -> CGSize {
        guard photo.width > 0, photo.height > 0 else { return .zero }
        let fit = min(view.width / photo.width, view.height / photo.height) * scale
        return CGSize(width: photo.width * fit, height: photo.height * fit)
    }

    func zoom(by factor: CGFloat, around point: CGPoint, photo: CGSize, in view: CGSize) -> Self {
        let next = min(8, max(1, scale * factor))
        let ratio = next / scale
        let x = point.x - view.width / 2
        let y = point.y - view.height / 2
        return Self(scale: next, offset: CGSize(width: x + (offset.width - x) * ratio,
                                                height: y + (offset.height - y) * ratio))
            .panned(by: .zero, photo: photo, in: view)
    }

    func panned(by delta: CGSize, photo: CGSize, in view: CGSize) -> Self {
        guard scale > 1 else { return Self() }
        let size = imageSize(photo, in: view)
        let x = max(0, (size.width - view.width) / 2)
        let y = max(0, (size.height - view.height) / 2)
        return Self(scale: scale, offset: CGSize(width: min(x, max(-x, offset.width + delta.width)),
                                                 height: min(y, max(-y, offset.height + delta.height))))
    }
}

struct ZoomablePhoto<Overlay: View>: View {
    let image: Image
    let size: CGSize
    @ViewBuilder let overlay: () -> Overlay
    @State private var viewport = PhotoViewport()
    @GestureState private var pinch: MagnifyGesture.Value?
    @GestureState private var drag: CGSize = .zero

    var body: some View {
        GeometryReader { geometry in
            let view = geometry.size
            let current = pinch.map {
                viewport.zoom(by: $0.magnification, around: $0.startLocation, photo: size, in: view)
            } ?? viewport.panned(by: drag, photo: size, in: view)
            let frame = current.imageSize(size, in: view)
            ZStack {
                // Keep the drag surface behind the crop handles, which have their own gestures.
                Color.clear.contentShape(Rectangle())
                    .gesture(viewport.scale > 1 ? pan(in: view) : nil)
                image.resizable().allowsHitTesting(false)
                    .overlay { overlay() }
                    .frame(width: frame.width, height: frame.height)
                    .offset(current.offset)
            }
            .frame(width: view.width, height: view.height)
            .clipped()
            .contentShape(Rectangle())
            .simultaneousGesture(MagnifyGesture()
                .updating($pinch) { value, state, _ in state = value }
                .onEnded { value in
                    viewport = viewport.zoom(by: value.magnification, around: value.startLocation, photo: size, in: view)
                })
            .onChange(of: view) { _, newSize in
                viewport = viewport.panned(by: .zero, photo: size, in: newSize)
            }
        }
    }

    private func pan(in view: CGSize) -> some Gesture {
        DragGesture()
            .updating($drag) { value, state, _ in if pinch == nil { state = value.translation } }
            .onEnded { value in
                if pinch == nil { viewport = viewport.panned(by: value.translation, photo: size, in: view) }
            }
    }
}

extension ZoomablePhoto where Overlay == EmptyView {
    init(image: Image, size: CGSize) {
        self.init(image: image, size: size) { EmptyView() }
    }
}
