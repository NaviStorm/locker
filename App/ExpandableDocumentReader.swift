import SwiftUI

// Move the live reader so PDF page, photo zoom and text scroll survive resizing.
struct ExpandableDocumentReader<Reader: View> {
    @Binding var expanded: Bool
    let reader: Reader

    init(expanded: Binding<Bool>, @ViewBuilder reader: () -> Reader) {
        _expanded = expanded
        self.reader = reader()
    }
}

#if os(iOS)
extension ExpandableDocumentReader: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Container {
        Container(reader: reader)
    }

    func updateUIViewController(_ container: Container, context: Context) {
        container.host.rootView = reader
        container.requestFullScreen(expanded)
    }

    static func dismantleUIViewController(_ container: Container, coordinator: ()) {
        container.retire()
    }

    final class Container: UIViewController {
        let host: UIHostingController<Reader>
        private var wantsFullScreen = false
        private var retired = false

        init(reader: Reader) {
            host = UIHostingController(rootView: reader)
            super.init(nibName: nil, bundle: nil)
            // Keep the vault hierarchy live so locking or closing can dismiss the reader.
            host.modalPresentationStyle = .overFullScreen
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidLoad() {
            super.viewDidLoad()
            embedReader()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            if wantsFullScreen { applyPresentation() }
        }

        private func embedReader() {
            guard !retired, host.parent == nil, host.presentingViewController == nil else { return }
            addChild(host)
            host.view.frame = view.bounds
            host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(host.view)
            host.didMove(toParent: self)
        }

        func requestFullScreen(_ expanded: Bool) {
            guard wantsFullScreen != expanded else { return }
            wantsFullScreen = expanded
            // UIKit must change containment after SwiftUI finishes updating the hierarchy.
            DispatchQueue.main.async { [weak self] in self?.applyPresentation() }
        }

        private func applyPresentation() {
            guard !retired else { return }
            if wantsFullScreen {
                guard viewIfLoaded?.window != nil, host.parent === self else { return }
                host.willMove(toParent: nil)
                host.view.removeFromSuperview()
                host.removeFromParent()
                present(host, animated: false)
            } else if host.presentingViewController != nil, !host.isBeingDismissed {
                host.dismiss(animated: false) { [weak self] in self?.embedReader() }
            }
        }

        func retire() {
            retired = true
            if host.presentingViewController != nil { host.dismiss(animated: false) }
        }
    }
}
#else
extension ExpandableDocumentReader: NSViewRepresentable {

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        let host = NSHostingView(rootView: reader)
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        context.coordinator.host = host
        return container
    }

    final class Coordinator {
        var host: NSHostingView<Reader>?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func updateNSView(_ container: NSView, context: Context) {
        guard let host = context.coordinator.host else { return }
        host.rootView = reader
        if expanded, !host.isInFullScreenMode {
            guard let screen = container.window?.screen,
                  host.enterFullScreenMode(screen, withOptions: [.fullScreenModeAllScreens: false]) else {
                DispatchQueue.main.async { expanded = false }
                return
            }
        } else if !expanded, host.isInFullScreenMode {
            host.exitFullScreenMode(options: nil)
        }
    }

    static func dismantleNSView(_ container: NSView, coordinator: Coordinator) {
        if let host = coordinator.host, host.isInFullScreenMode { host.exitFullScreenMode(options: nil) }
    }
}
#endif
