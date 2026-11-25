#if os(iOS)
import CloudKit
import SwiftUI

@MainActor @Observable
private final class NearbyFamilyPairing {
    enum Phase { case searching, comparing, preparing, waitingForJoin, finished, failed }
    var phase = Phase.searching
    var message = "Connexion au compte iCloud…"
    var handshake: NearbyHandshake?
    private var link: NearbyFamilyLink?
    private var work: Task<Void, Never>?
    private var timeout: Task<Void, Never>?

    func start(role: NearbyRole, model: LockerModel, store: VaultStore) async {
        stop()
        phase = .searching
        message = "Connexion au compte iCloud…"
        do {
            guard let bundle = Bundle.main.bundleIdentifier else { throw VaultError.unavailable }
            let card = try await store.publicIdentity()
            let account = try await CKContainer(identifier: "iCloud." + bundle).userRecordID()
            try Task.checkCancellation()
            try store.gate.check()
            guard model.store === store else { throw VaultError.locked }
            handshake = NearbyHandshake(role: role, card: card, account: account.recordName)
            let channel = NearbyFamilyLink()
            link = channel
            channel.onConnected = { [weak self] in
                guard let self, let handshake = self.handshake else { return }
                if role == .owner {
                    do { try self.link?.send(.commitment(handshake.local.digest)) }
                    catch { self.fail(error.localizedDescription) }
                }
            }
            channel.onPacket = { [weak self] packet in self?.receive(packet, model: model, store: store) }
            channel.onFailure = { [weak self] reason in self?.fail(reason) }
            message = role == .owner
                ? "Sur l’autre iPhone, ouvrez Partage familial et touchez « Recevoir un coffre »."
                : "Sur l’autre iPhone, ouvrez Partage familial et touchez « Inviter à proximité »."
            channel.start(as: role)
            setTimeout()
        } catch {
            if !Task.isCancelled { fail(error.localizedDescription) }
        }
    }

    private func setTimeout() {
        timeout?.cancel()
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(120)) } catch { return }
            self?.fail("Le jumelage a expiré. Gardez Locker ouvert sur les deux iPhones, avec le Wi-Fi activé, puis réessayez.")
        }
    }

    func confirm(model: LockerModel, store: VaultStore) {
        guard phase == .comparing, let link else { return }
        do {
            try store.gate.check()
            guard let packet = try handshake?.confirm() else { throw FamilyError.policy }
            try link.send(packet)
            model.activity()
            beginIfReady(model: model, store: store)
        } catch { fail(error.localizedDescription) }
    }

    private func receive(_ packet: NearbyHandshake.Packet, model: LockerModel, store: VaultStore) {
        do {
            try store.gate.check()
            guard model.store === store, let link else { throw VaultError.locked }
            switch packet {
            case let .ticket(ticket):
                guard phase == .preparing, let handshake, handshake.role == .guest, handshake.ready,
                      let owner = handshake.peer?.card, work == nil else { throw FamilyError.policy }
                work = Task {
                    do {
                        try Task.checkCancellation()
                        try await store.joinFamily(ticket, from: owner)
                        guard model.store === store else { throw VaultError.locked }
                        model.familyMode = true
                        try await model.configure(ProviderSettings(provider: .cloud), credential: nil)
                        phase = .finished
                        message = "Coffre rejoint. Les documents arriveront par iCloud."
                        timeout?.cancel()
                        try? link.send(.joined)
                    } catch { fail(error.localizedDescription) }
                }
            case .joined:
                guard phase == .waitingForJoin, handshake?.role == .owner else { throw FamilyError.policy }
                phase = .finished
                message = "Le proche a rejoint le coffre. Les documents sont partagés par iCloud."
                timeout?.cancel()
            default:
                guard phase == .searching || phase == .comparing else { throw FamilyError.policy }
                if let reply = try handshake?.receive(packet) { try link.send(reply) }
                if handshake?.code != nil { phase = .comparing }
                beginIfReady(model: model, store: store)
            }
        } catch { fail(error.localizedDescription) }
    }

    private func beginIfReady(model: LockerModel, store: VaultStore) {
        guard let handshake, handshake.ready, phase == .comparing else { return }
        phase = .preparing
        message = "Configuration du partage iCloud…"
        setTimeout()
        guard handshake.role == .owner, let card = handshake.peer?.card, let account = handshake.guestAccount else { return }
        work = Task {
            do {
                try Task.checkCancellation()
                if try await store.canStartFamily() { try await store.createFamily() }
                guard model.store === store else { throw VaultError.locked }
                model.familyMode = true
                if model.configuration.provider == .local {
                    try await model.configure(ProviderSettings(provider: .cloud), credential: nil)
                }
                try Task.checkCancellation()
                let ticket = try await store.issueNearbyTicket(to: card, account: account)
                try Task.checkCancellation()
                guard let link else { throw VaultError.unavailable }
                phase = .waitingForJoin
                message = "Invitation transmise. En attente de l’autre iPhone…"
                try link.send(.ticket(ticket))
                model.sync()
            } catch { fail(error.localizedDescription) }
        }
    }

    func stop() {
        link?.stop()
        link = nil
        timeout?.cancel()
        work?.cancel()
        work = nil
        handshake = nil
    }

    private func fail(_ reason: String) {
        guard phase != .finished, phase != .failed else { return }
        stop()
        phase = .failed
        message = reason
    }
}

struct NearbyFamilyScreen: View {
    let model: LockerModel
    let role: NearbyRole
    let store: VaultStore
    @Environment(\.dismiss) private var dismiss
    @State private var pairing = NearbyFamilyPairing()
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if pairing.phase == .comparing, let code = pairing.handshake?.code {
                        Text("Vérifiez que les deux iPhones affichent le même code.")
                        Text(code).font(.system(.largeTitle, design: .monospaced).bold())
                        Text(role == .owner
                             ? "Ce proche pourra lire tous les documents de ce coffre familial avec son compte iCloud."
                             : "Vous recevrez les documents de ce coffre familial en lecture sur votre compte iCloud.")
                        if pairing.handshake?.confirmedHere == true {
                            Text("En attente de la confirmation sur l’autre iPhone…")
                        } else {
                            Button("Les codes correspondent") { pairing.confirm(model: model, store: store) }
                            Button("Refuser", role: .cancel) { pairing.stop(); dismiss() }
                        }
                    } else {
                        if pairing.phase != .failed && pairing.phase != .finished { ProgressView() }
                        Text(pairing.message)
                        if pairing.phase == .failed { Text("Fermez cet écran pour recommencer.").font(.footnote) }
                    }
                }
            }
            .navigationTitle("iPhone à proximité")
            .modifier(VaultDismissToolbar())
        }
        .task { await pairing.start(role: role, model: model, store: store) }
        .onDisappear { pairing.stop() }
    }
}
#endif
