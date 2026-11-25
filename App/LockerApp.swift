import SwiftUI

@main
struct LockerApp: App {
    @State private var model = LockerModel()
    var body: some Scene {
        #if os(macOS)
        Window("Locker", id: "locker") { RootScreen(model: model).frame(minWidth: 480, minHeight: 460) }
            .defaultSize(width: 900, height: 650)
        #else
        WindowGroup { RootScreen(model: model).modifier(DuoPostureReader()) }
        #endif
    }
}

struct RootScreen: View {
    @Bindable var model: LockerModel
    @Environment(\.scenePhase) private var phase
    @State private var code = ""
    @State private var unlockSecret = ""
    @State private var protectNewKey = true
    @State private var recovering = false
    #if os(iOS)
    @Environment(\.duoPosture) private var duoPosture
    private var partiallyOpen: Bool { duoPosture == .folded }
    #else
    private let partiallyOpen = false
    #endif

    var body: some View {
        Group {
            if model.store != nil {
                LibraryScreen(model: model)
            } else {
                welcome
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .top, spacing: 0) { IncomingShares(model: model) }
        .background(PrivacyMonitor(activity: { model.activity() }, background: {
            code = ""
            unlockSecret = ""
            #if os(macOS)
            if !model.changingProtection && (!model.opening || model.store != nil) { model.lock() }
            #else
            model.lock()
            #endif
        }))
        .tint(Color.lockerTint)
        .privacySensitive()
        .onChange(of: model.store != nil) { _, opened in
            if opened { protectNewKey = true; unlockSecret = "" }
        }
        .onChange(of: model.slot) { unlockSecret = "" }
        .onChange(of: recovering) { unlockSecret = "" }
        .onChange(of: phase) { _, new in
            if new == .background { code = ""; model.lock() }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                model.tick()
            }
        }
        .sheet(item: $model.newVaultSetup) { setup in
            NewVaultSecretSettings(mode: setup.mode) { credential in
                model.completeNewVaultSetup(setup, with: credential)
            }
        }
        .modifier(LocalVaultRemovalDialog(model: model, request: $model.removalRequest))
        .alert("Locker", isPresented: Binding(get: { model.problem != nil }, set: { if !$0 { model.problem = nil } })) {
            Button("Fermer") { model.problem = nil }
        } message: { Text(model.problem ?? "") }
    }

    private var welcome: some View {
        VaultWelcomeLayout(partiallyOpen: partiallyOpen,
                          showCompactCover: !model.authenticationMethod.isCustom || recovering) {
            accessControls
        }
    }

    private func unlockSelected(after: (() -> Void)? = nil) {
        let mode: AccessMode = model.authenticationMethod.isCustom ? .unlockWithSecret(unlockSecret) : .unlock
        unlockSecret = ""
        model.open(mode, afterOpen: after)
    }

    private var accessControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !model.slots.isEmpty && !recovering {
                Picker("Coffre local", selection: $model.slot) {
                    ForEach(model.slots, id: \.self) {
                        Text(model.pickerTitle(for: $0)).tag($0)
                    }
                }
                if model.authenticationMethod.isCustom {
                    UnlockSecretField(method: model.authenticationMethod, text: $unlockSecret)
                }
                Button {
                    unlockSelected()
                } label: {
                    Label("Ouvrir le coffre", systemImage: "lock.open")
                        .frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(model.authenticationMethod.isCustom && unlockSecret.isEmpty)
                if model.vaultKinds[model.slot] != .family {
                    Button("Supprimer de cet appareil…", role: .destructive) {
                        unlockSelected { model.requestLocalRemoval() }
                    }.disabled(model.authenticationMethod.isCustom && unlockSecret.isEmpty)
                }
                Divider()
            }

            if recovering {
                Label("Récupération", systemImage: "key").font(.title3.weight(.semibold))
                SecureField("Code de récupération", text: $code).textFieldStyle(.roundedBorder)
                if !model.slots.isEmpty {
                    Toggle("Réparer le coffre sélectionné", isOn: $model.repairSelected)
                    if model.repairSelected {
                        if model.authenticationMethod.isCustom {
                            #if targetEnvironment(simulator)
                            Text("Le code de récupération permet de choisir un nouveau secret pour ce coffre.").font(.footnote)
                            #else
                            Text("Après vérification du code de récupération, le coffre utilisera l’authentification système.").font(.footnote)
                            #endif
                        }
                        Picker("Coffre à réparer", selection: $model.slot) {
                            ForEach(model.slots, id: \.self) {
                                Text(model.pickerTitle(for: $0)).tag($0)
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
        .disabled(model.opening || model.removingVault)
    }
}

struct VaultWelcomeLayout<Controls: View>: View {
    let partiallyOpen: Bool
    let showCompactCover: Bool
    @ViewBuilder let controls: () -> Controls

    var body: some View {
        GeometryReader { geometry in
            #if os(iOS)
            if #available(iOS 27.1, *), partiallyOpen {
                folded(geometry)
            } else { standard(geometry) }
            #else
            standard(geometry)
            #endif
        }
        .background(Color.lockerCanvas)
    }

    #if os(iOS)
    @available(iOS 27.1, *)
    private func folded(_ geometry: GeometryProxy) -> some View {
        let width = geometry.size.width
        let (left, rightStart) = geometry.duoColumnEdges
        return HStack(spacing: rightStart - left) {
            Image("LockerMark")
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 140, maxHeight: 140)
                .clipShape(RoundedRectangle(cornerRadius: 28))
                .padding()
                .frame(width: left)
                .accessibilityLabel("Locker")
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Locker")
                        .font(.system(.title, design: .rounded, weight: .bold))
                        .padding([.horizontal, .top], 12)
                    controls()
                }
                .padding(8)
                .background(.background, in: RoundedRectangle(cornerRadius: 20))
                .padding(12)
                .frame(maxWidth: 480, minHeight: geometry.size.height)
                .frame(maxWidth: .infinity)
            }
            .frame(width: width - rightStart)
        }
    }
    #endif

    private func standard(_ geometry: GeometryProxy) -> some View {
        let wide = geometry.size.width >= 740
        return ScrollView {
            let layout = wide ? AnyLayout(HStackLayout(spacing: 26)) : AnyLayout(VStackLayout(spacing: 20))
            layout {
                if wide || geometry.size.height >= 440 || showCompactCover {
                    LockerCover(compact: !wide)
                        .frame(maxWidth: wide ? 250 : .infinity)
                        .frame(height: wide ? 276 : nil)
                }
                controls()
            }
            .padding(14)
            .frame(maxWidth: wide ? 800 : 440)
            .background(.background, in: RoundedRectangle(cornerRadius: 28))
            .overlay { RoundedRectangle(cornerRadius: 28).strokeBorder(.primary.opacity(0.07)) }
            .padding(wide ? 32 : 16)
            .frame(maxWidth: .infinity, minHeight: geometry.size.height)
        }
    }
}

struct UnlockSecretField: View {
    let method: VaultAuthenticationMethod
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(method.secretTitle)
                .font(.headline)
                .accessibilityHidden(true)
            VaultSecretField(title: method == .numericCode ? "Saisissez votre code" : "Saisissez votre mot de passe",
                             method: method, text: $text)
                .textFieldStyle(.plain)
                .focused($focused)
                .accessibilityLabel(method.secretTitle)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(.background, in: RoundedRectangle(cornerRadius: 9))
                .overlay {
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(focused ? Color.accentColor : .secondary, lineWidth: focused ? 2 : 1)
                        .allowsHitTesting(false)
                }
                .contentShape(Rectangle())
                .simultaneousGesture(TapGesture().onEnded { focused = true })
        }
    }
}

struct LocalVaultRemovalDialog: ViewModifier {
    let model: LockerModel
    @Binding var request: String?

    func body(content: Content) -> some View {
        content
        .confirmationDialog("Supprimer « \(model.pickerTitle(for: request ?? model.slot)) » de cet appareil ?",
            isPresented: Binding(get: { request != nil }, set: { if !$0 { request = nil } }),
            titleVisibility: .visible, presenting: request) { id in
            Button("Supprimer le coffre local", role: .destructive) { Task { await model.removeUnsharedVault(id) } }
            Button("Annuler", role: .cancel) {}
        } message: { _ in
            Text("Les documents, leurs versions et les modifications en attente seront effacés de cet appareil. Les copies déjà synchronisées resteront chez le fournisseur.")
        }
    }
}
