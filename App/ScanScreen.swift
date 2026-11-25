import AVFoundation
import SwiftUI
#if os(iOS)
import VisionKit
#else
import PDFKit
#endif

enum CaptureSource: String, CaseIterable, Identifiable {
    case photo, document
    var id: Self { self }
    var title: String { self == .photo ? "Prendre une photo" : "Scanner un document en PDF" }
    var symbol: String { self == .photo ? "camera" : "document.viewfinder" }
    var available: Bool {
        #if os(iOS)
        switch self {
        case .photo: return UIImagePickerController.isSourceTypeAvailable(.camera)
        case .document: return VNDocumentCameraViewController.isSupported
        }
        #else
        return AVCaptureDevice.default(for: .video) != nil
        #endif
    }
}

struct ScanResult {
    let bytes: Data
    let name: String
}

#if os(iOS)
struct CaptureScreen: View {
    let source: CaptureSource
    let complete: (Result<ScanResult, Error>) -> Void
    let cancel: () -> Void
    @State private var authorized = false

    var body: some View {
        Group {
            if authorized {
                switch source {
                case .document: ScanScreen(complete: complete, cancel: cancel)
                case .photo: PhotoCamera(complete: complete, cancel: cancel)
                }
            } else {
                ProgressView("Ouverture de la caméra…")
            }
        }
        .task {
            guard source.available else {
                complete(.failure(TransportError(message: "La caméra est indisponible sur cet appareil.")))
                return
            }
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            guard !Task.isCancelled else { return }
            if granted { authorized = true }
            else { complete(.failure(TransportError(message: "Autorisez Locker à utiliser la caméra dans les réglages de confidentialité."))) }
        }
    }
}

private struct PhotoCamera: UIViewControllerRepresentable {
    let complete: (Result<ScanResult, Error>) -> Void
    let cancel: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let controller = UIImagePickerController()
        controller.sourceType = .camera
        controller.cameraCaptureMode = .photo
        controller.delegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let screen: PhotoCamera
        init(_ screen: PhotoCamera) { self.screen = screen }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { screen.cancel() }
        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            guard let image = info[.originalImage] as? UIImage, let bytes = image.jpegData(compressionQuality: 0.95) else {
                screen.complete(.failure(TransportError(message: "Impossible de lire la photographie.")))
                return
            }
            screen.complete(.success(ScanResult(bytes: bytes, name: "Photographie.jpg")))
        }
    }
}

private struct ScanScreen: UIViewControllerRepresentable {
    let complete: (Result<ScanResult, Error>) -> Void
    let cancel: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let scanner = VNDocumentCameraViewController()
        scanner.delegate = context.coordinator
        return scanner
    }
    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}
    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let screen: ScanScreen
        init(_ screen: ScanScreen) { self.screen = screen }
        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) { screen.cancel() }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            screen.complete(.failure(error))
        }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            guard scan.pageCount > 0 else { screen.cancel(); return }
            let bytes = ScanResult.pdf(pageCount: scan.pageCount, page: scan.imageOfPage(at:))
            screen.complete(.success(ScanResult(bytes: bytes, name: "Numérisation.pdf")))
        }
    }
}
extension ScanResult {
    static func pdf(pageCount: Int, page: (Int) -> UIImage) -> Data {
        let bounds = CGRect(x: 0, y: 0, width: 595, height: 842)
        return UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            for index in 0..<pageCount {
                autoreleasepool {
                    let image = page(index)
                    let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
                    let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                    context.beginPage()
                    image.draw(in: CGRect(origin: CGPoint(x: (bounds.width - size.width) / 2,
                                                          y: (bounds.height - size.height) / 2), size: size))
                }
            }
        }
    }
}
#else
struct CaptureScreen: View {
    let source: CaptureSource
    let complete: (Result<ScanResult, Error>) -> Void
    let cancel: () -> Void
    @StateObject private var camera = Camera()
    @State private var pages: [PDFPage] = []
    var body: some View {
        VStack {
            CameraPreview(session: camera.session).frame(minWidth: 320, minHeight: 240)
            HStack {
                Button("Annuler", action: cancel)
                if source == .photo {
                    Button("Photographier") { camera.capture(complete) }.disabled(!camera.ready)
                } else {
                    Button("Capturer une page") {
                        camera.capture { result in
                            do {
                                let shot = try result.get()
                                guard let image = NSImage(data: shot.bytes), let page = PDFPage(image: image) else {
                                    throw TransportError(message: "Impossible de créer la page du document.")
                                }
                                pages.append(page)
                            } catch { complete(.failure(error)) }
                        }
                    }.disabled(!camera.ready)
                    Button("Enregistrer le PDF") {
                        let document = PDFDocument()
                        for page in pages { document.insert(page, at: document.pageCount) }
                        guard let bytes = document.dataRepresentation() else {
                            complete(.failure(TransportError(message: "Impossible de créer le PDF.")))
                            return
                        }
                        complete(.success(ScanResult(bytes: bytes, name: "Numérisation.pdf")))
                    }.disabled(pages.isEmpty || !camera.ready)
                }
            }
            if source == .document && !pages.isEmpty {
                HStack {
                    Text("Pages capturées : \(pages.count)")
                    Button("Retirer la dernière page") { pages.removeLast() }
                }
            }
        }.padding().task {
            do { try await camera.start() } catch { complete(.failure(error)) }
        }.onDisappear { camera.stop() }
    }

    private final class Camera: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
        let session = AVCaptureSession()
        let output = AVCapturePhotoOutput()
        let queue = DispatchQueue(label: "Locker.Camera")
        @Published var ready = false
        var completion: ((Result<ScanResult, Error>) -> Void)?
        func start() async throws {
            guard await AVCaptureDevice.requestAccess(for: .video) else { throw TransportError(message: "Accès caméra refusé.") }
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                queue.async {
                    do {
                        guard let device = AVCaptureDevice.default(for: .video) else { throw VaultError.unavailable }
                        let input = try AVCaptureDeviceInput(device: device)
                        guard self.session.canAddInput(input), self.session.canAddOutput(self.output) else { throw VaultError.unavailable }
                        self.session.addInput(input)
                        self.session.addOutput(self.output)
                        self.session.startRunning()
                        DispatchQueue.main.async { self.ready = true }
                        continuation.resume()
                    } catch { continuation.resume(throwing: error) }
                }
            }
        }
        func capture(_ handler: @escaping (Result<ScanResult, Error>) -> Void) {
            completion = handler
            ready = false
            output.capturePhoto(with: AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg]), delegate: self)
        }
        func stop() { completion = nil; queue.async { self.session.stopRunning() } }
        func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
            let bytes = photo.fileDataRepresentation()
            DispatchQueue.main.async {
                self.ready = true
                if let bytes { self.completion?(.success(ScanResult(bytes: bytes, name: "Photographie.jpg"))) }
                else { self.completion?(.failure(error ?? VaultError.unavailable)) }
                self.completion = nil
            }
        }
    }
    private struct CameraPreview: NSViewRepresentable {
        let session: AVCaptureSession
        func makeNSView(context: Context) -> NSView {
            let view = NSView()
            view.wantsLayer = true
            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspect
            view.layer = layer
            return view
        }
        func updateNSView(_ view: NSView, context: Context) {}
    }
}
#endif
