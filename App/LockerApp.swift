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
    @State private var recovering = false

    var body: some View {
        Group {
            if model.store != nil {
                LibraryScreen(model: model)
            } else {
                VStack(spacing: 18) {
                    Image(systemName: "lock.shield").font(.system(size: 52, weight: .light)).foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    Text("Locker").font(.largeTitle.bold())
                    if !model.slots.isEmpty {
                        Picker("Coffre local", selection: $model.slot) {
                            ForEach(model.slots, id: \.self) { Text("Coffre " + $0.prefix(8)).tag($0) }
                        }.frame(maxWidth: 330)
                        Button("Déverrouiller") { model.open(.unlock) }.buttonStyle(.borderedProminent)
                    }
                    if recovering {
                        SecureField("Code de récupération", text: $code).textFieldStyle(.roundedBorder)
                        Button("Récupérer le coffre") {
                            let entered = code
                            code = ""
                            recovering = false
                            model.open(.recover(entered), newSlot: model.slots.isEmpty || !model.repairSelected)
                        }.disabled(code.isEmpty)
                        if !model.slots.isEmpty {
                            Toggle("Réparer le coffre sélectionné", isOn: $model.repairSelected)
                        }
                    } else {
                        Button("Créer un coffre") { model.open(.create, newSlot: true) }
                        Button("Utiliser un code de récupération") { recovering = true }
                    }
                    if model.opening { ProgressView("Authentification…") }
                }.padding(32).frame(maxWidth: 430).disabled(model.opening)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PrivacyMonitor(activity: { model.activity() }, background: {
            code = ""
            #if os(macOS)
            if !model.opening { model.lock() }
            #else
            model.lock()
            #endif
        }))
        .privacySensitive()
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
}
