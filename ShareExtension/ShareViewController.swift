import SwiftUI

#if os(macOS)
import AppKit
typealias PlatformController = NSViewController
#else
import UIKit
typealias PlatformController = UIViewController
#endif

final class ShareViewController: PlatformController {
    #if os(macOS)
    override func loadView() { view = NSView() }
    #endif

    override func viewDidLoad() {
        super.viewDidLoad()
        preferredContentSize = CGSize(width: 400, height: 230)
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        let screen = ReceiveShare(providers: providers, finish: { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }, cancel: { [weak self] in
            self?.extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
        })
        #if os(macOS)
        view = NSHostingView(rootView: screen)
        #else
        let host = UIHostingController(rootView: screen)
        addChild(host)
        view.addSubview(host.view)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.didMove(toParent: self)
        #endif
    }
}

private struct ReceiveShare: View {
    let providers: [NSItemProvider]
    let finish: () -> Void
    let cancel: () -> Void
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Envoyer à Locker", systemImage: "lock.doc").font(.title2.bold())
            Text("Ouvrez ensuite le coffre de destination dans Locker pour y importer les éléments partagés.")
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Button("Annuler", action: cancel)
                Spacer()
                if busy { ProgressView() }
                Button("Envoyer") {
                    busy = true
                    error = nil
                    Task {
                        do {
                            try await Self.receive(providers)
                            finish()
                        } catch { self.error = error.localizedDescription; busy = false }
                    }
                }.buttonStyle(.borderedProminent)
            }.disabled(busy)
        }.padding(24)
    }

    private static func receive(_ providers: [NSItemProvider]) async throws {
        let writer = try ShareInbox.Writer(.local())
        defer { try? FileManager.default.removeItem(at: writer.staging) }
        var items = [ShareInbox.Item]()
        for provider in providers { items.append(try await writer.receive(provider)) }
        try writer.finish(items)
    }
}
