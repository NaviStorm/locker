import SwiftUI

struct VaultDismissToolbar: ViewModifier {
    @Environment(\.dismiss) private var dismiss
    @State private var closed = false

    func body(content: Content) -> some View {
        #if os(iOS)
        if #available(iOS 27.1, *) {
            content
                .onHingeChange { _, context in closed = context.hinge?.status == .closed }
                .toolbar {
                    if closed {
                        ToolbarItem(placement: .bottomBar) {
                            Button("Retour", systemImage: "chevron.backward") { dismiss() }
                                .labelStyle(.iconOnly)
                        }.axisBehavior(.verticalPreferred)
                    } else { closeButton }
                }
        } else { content.toolbar { closeButton } }
        #else
        content.toolbar { closeButton }
        #endif
    }

    private var closeButton: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) { Button("Fermer") { dismiss() } }
    }
}

extension View {
    @ViewBuilder
    func lockerPanel<Panel: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Panel) -> some View {
        #if os(iOS)
        if #available(iOS 27.1, *) {
            modifier(HingeAwarePanel(requested: isPresented, panel: content))
        } else { sheet(isPresented: isPresented, content: content) }
        #else
        sheet(isPresented: isPresented, content: content)
        #endif
    }
}

#if os(iOS)
@available(iOS 27.1, *)
private struct HingeAwarePanel<Panel: View>: ViewModifier {
    @Binding var requested: Bool
    let panel: () -> Panel
    @State private var closed = false
    @State private var fullScreen = false
    @State private var sheet = false

    func body(content: Content) -> some View {
        content
            .onHingeChange { _, context in closed = context.hinge?.status == .closed }
            .onChange(of: requested) { _, show in
                guard show else { return }
                if closed { fullScreen = true } else { sheet = true }
            }
            .fullScreenCover(isPresented: $fullScreen, onDismiss: { requested = false }, content: panel)
            .sheet(isPresented: $sheet, onDismiss: { requested = false }, content: panel)
    }
}
#endif
