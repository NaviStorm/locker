import SwiftUI

@main
struct LockerApp: App {
    @State private var model = LockerModel()
    var body: some Scene {
        #if os(macOS)
        Window("Locker", id: "locker") { RootScreen(model: model).frame(minWidth: 480, minHeight: 460) }
            .defaultSize(width: 900, height: 650)
        #else
        WindowGroup { RootScreen(model: model) }
        #endif
    }
}

struct RootScreen: View {
    @Bindable var model: LockerModel
    @Environment(\.scenePhase) private var phase
    @State private var code = ""
    @State private var protectNewKey = true
    @State private var recovering = false

    var body: some View {
        Group {
            if model.store != nil {
                LibraryScreen(model: model)
            } else {
                GeometryReader { geometry in
                    let wide = geometry.size.width >= 740
                    ScrollView {
                        let layout = wide ? AnyLayout(HStackLayout(spacing: 26)) : AnyLayout(VStackLayout(spacing: 20))
                        layout {
                            LockerCover(compact: !wide)
                                .frame(maxWidth: wide ? 250 : .infinity)
                                .frame(height: wide ? 276 : nil)
                            accessControls
                        }
                        .padding(14)
                        .frame(maxWidth: wide ? 800 : 440)
                        .background(.background, in: RoundedRectangle(cornerRadius: 28))
                        .overlay { RoundedRectangle(cornerRadius: 28).strokeBorder(.primary.opacity(0.07)) }
                        .padding(wide ? 32 : 16)
                        .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                    }
                    .background(Color.lockerCanvas)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .top, spacing: 0) { IncomingShares(model: model) }
        .background(PrivacyMonitor(activity: { model.activity() }, background: {
            code = ""
            #if os(macOS)
            if !model.changingProtection && (!model.opening || model.store != nil) { model.lock() }
            #else
            model.lock()
            #endif
        }))
        .tint(Color.lockerTint)
        .privacySensitive()
        .onChange(of: model.store != nil) { _, opened in
            if opened { protectNewKey = true }
        }
        .onChange(of: phase) { _, new in
            if new == .background { code = ""; model.lock() }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                model.tick()
            }
        }
        .alert("Locker", isPresented: Binding(get: { model.problem != nil }, set: { if !$0 { model.problem = nil } })) {
            Button("Fermer") { model.problem = nil }
        } message: { Text(model.problem ?? "") }
    }

    private var accessControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !model.slots.isEmpty && !recovering {
                Picker("Coffre local", selection: $model.slot) {
                    ForEach(model.slots, id: \.self) {
                        Text(model.vaultNames[$0] ?? ("Coffre " + $0.prefix(8))).tag($0)
                    }
                }
                Button {
                    model.open(.unlock)
                } label: {
                    Label("Ouvrir le coffre", systemImage: "lock.open")
                        .frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).controlSize(.large)
                Divider()
            }

            if recovering {
                Label("Récupération", systemImage: "key").font(.title3.weight(.semibold))
                SecureField("Code de récupération", text: $code).textFieldStyle(.roundedBorder)
                if !model.slots.isEmpty {
                    Toggle("Réparer le coffre sélectionné", isOn: $model.repairSelected)
                    if model.repairSelected {
                        Picker("Coffre à réparer", selection: $model.slot) {
                            ForEach(model.slots, id: \.self) {
                                Text(model.vaultNames[$0] ?? ("Coffre " + $0.prefix(8))).tag($0)
                            }
                        }
                    }
                }
            }

            if !recovering || model.slots.isEmpty || !model.repairSelected {
                Toggle("Exiger une authentification pour le nouveau coffre", isOn: $protectNewKey)
                    .font(.callout)
            }
            if recovering {
                Button("Récupérer le coffre") {
                    let entered = code
                    code = ""
                    recovering = false
                    model.open(.recover(entered), newSlot: model.slots.isEmpty || !model.repairSelected, protectNewKey: protectNewKey)
                }.buttonStyle(.borderedProminent).disabled(code.isEmpty)
                Button("Annuler") { code = ""; recovering = false }
            } else {
                let create = Button {
                    model.open(.create, newSlot: true, protectNewKey: protectNewKey)
                } label: {
                    Label("Créer un coffre", systemImage: "plus").frame(maxWidth: .infinity)
                }.controlSize(.large)
                if model.slots.isEmpty { create.buttonStyle(.borderedProminent) }
                else { create.buttonStyle(.bordered) }
                Button("Utiliser un code de récupération") { recovering = true }
                    .font(.callout)
            }
            if model.opening { ProgressView("Ouverture du coffre…") }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .disabled(model.opening)
    }
}
