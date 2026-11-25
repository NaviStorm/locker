import SwiftUI

#if os(macOS)
import AppKit
typealias PlatformController = NSViewController
#else
import UIKit
typealias PlatformController = UIViewController
#endif

final class ShareViewController: PlatformController {
    private func attachments() -> [NSItemProvider] {
        (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
    }

    #if os(macOS)
    private var transfer: Progress?
    private let status = NSTextField(wrappingLabelWithString:
        "Ouvrez ensuite le coffre de destination dans Locker pour y importer les éléments partagés.")
    private lazy var sendButton = NSButton(title: "Envoyer", target: self, action: #selector(sendShare))

    override func loadView() {
        let size = NSSize(width: 400, height: 230)
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        let title = NSTextField(labelWithString: "Envoyer à Locker")
        title.font = .boldSystemFont(ofSize: 20)
        let cancel = NSButton(title: "Annuler", target: self, action: #selector(cancelOperation(_:)))
        cancel.keyEquivalent = "\u{1b}"
        sendButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [cancel, sendButton])
        buttons.spacing = 12
        for item in [title, status, buttons] as [NSView] {
            item.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(item)
        }
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(greaterThanOrEqualToConstant: size.width),
            root.heightAnchor.constraint(greaterThanOrEqualToConstant: size.height),
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            status.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 16),
            status.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            buttons.topAnchor.constraint(greaterThanOrEqualTo: status.bottomAnchor, constant: 16),
            buttons.trailingAnchor.constraint(equalTo: status.trailingAnchor),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20)
        ])
        view = root
        preferredContentSize = size
    }

    override func cancelOperation(_ sender: Any?) {
        transfer?.cancel()
        extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
    }

    @objc private func sendShare() {
        guard transfer == nil else { return }
        let progress = Progress(totalUnitCount: -1)
        transfer = progress
        sendButton.isEnabled = false
        status.stringValue = "Réception des éléments en cours…"
        Task {
            do {
                try await receiveShare(attachments(), progress: progress) {
                    extensionContext?.completeRequest(returningItems: nil)
                }
            } catch {
                guard !progress.isCancelled else { return }
                status.stringValue = error.localizedDescription
                transfer = nil
                sendButton.isEnabled = true
            }
        }
    }
    #else
    override func viewDidLoad() {
        super.viewDidLoad()
        preferredContentSize = CGSize(width: 400, height: 230)
        let screen = ReceiveShare(providers: { [weak self] in self?.attachments() ?? [] }, finish: { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }, cancel: { [weak self] in
            self?.extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
        })
        let host = UIHostingController(rootView: screen)
        addChild(host)
        view.addSubview(host.view)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.didMove(toParent: self)
    }
    #endif
}

#if os(iOS)
private struct ReceiveShare: View {
    let providers: () -> [NSItemProvider]
    let finish: () -> Void
    let cancel: () -> Void
    @State private var transfer: Progress?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Envoyer à Locker", systemImage: "lock.doc").font(.title2.bold())
            Text("Ouvrez ensuite le coffre de destination dans Locker pour y importer les éléments partagés.")
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Button("Annuler") {
                    transfer?.cancel()
                    cancel()
                }
                Spacer()
                if transfer != nil { ProgressView() }
                Button("Envoyer", action: send)
                    .buttonStyle(.borderedProminent)
                    .disabled(transfer != nil)
            }
        }.padding(24)
    }

    private func send() {
        guard transfer == nil else { return }
        let progress = Progress(totalUnitCount: -1)
        transfer = progress
        error = nil
        let attachments = providers()
        Task { @MainActor in
            do {
                try await receiveShare(attachments, progress: progress, complete: finish)
            } catch {
                guard !progress.isCancelled else { return }
                self.error = error.localizedDescription
                transfer = nil
            }
        }
    }
}
#endif

@MainActor
private func receiveShare(_ attachments: [NSItemProvider], progress: Progress, complete: () -> Void) async throws {
    let writer = try ShareInbox.Writer(.local())
    defer { try? FileManager.default.removeItem(at: writer.staging) }
    var items = [ShareInbox.Item]()
    for provider in attachments {
        guard !progress.isCancelled else { throw CancellationError() }
        items.append(try await writer.receive(provider, checking: {
            if progress.isCancelled { throw CancellationError() }
        }))
    }
    // Cancellation and publication are serialized on the main actor.
    guard !progress.isCancelled else { throw CancellationError() }
    try writer.finish(items)
    complete()
}
