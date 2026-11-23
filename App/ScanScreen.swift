import SwiftUI

struct ScanResult {
    let bytes: Data
    let name: String
}

#if os(iOS)
import VisionKit
struct ScanScreen: UIViewControllerRepresentable {
    static var supported: Bool { VNDocumentCameraViewController.isSupported }
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
            let bounds = CGRect(x: 0, y: 0, width: 595, height: 842)
            let bytes = UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
                for index in 0..<scan.pageCount {
                    autoreleasepool {
                        let image = scan.imageOfPage(at: index)
                        let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
                        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                        context.beginPage()
                        image.draw(in: CGRect(origin: CGPoint(x: (bounds.width - size.width) / 2,
                                                              y: (bounds.height - size.height) / 2), size: size))
                    }
                }
            }
            screen.complete(.success(ScanResult(bytes: bytes, name: "Numérisation.pdf")))
        }
    }
}
#else
import AVFoundation

struct ScanScreen: View {
    let complete: (Result<ScanResult, Error>) -> Void
    let cancel: () -> Void
    @StateObject private var camera = Camera()
    var body: some View {
        VStack {
            CameraPreview(session: camera.session).frame(minWidth: 320, minHeight: 240)
            HStack {
                Button("Annuler", action: cancel)
                Button("Photographier") { camera.capture(complete) }.disabled(!camera.ready)
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
        func stop() { queue.async { self.session.stopRunning() } }
        func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
            let bytes = photo.fileDataRepresentation()
            DispatchQueue.main.async {
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
