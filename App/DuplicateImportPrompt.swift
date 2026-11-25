import SwiftUI

extension LockerModel {
    func importCaptured(_ data: Data, name: String, folder: String) {
        reviewImport { store, choices in
            try await store.importReviewedData(data, name: name, folder: folder, choices: choices)
        }
    }

    func resolveDuplicate(_ choice: DuplicateChoice?) {
        let pending = importAnswer
        importAnswer = nil
        duplicateImport = nil
        pending?.resume(returning: choice)
    }

    func reviewImport(extract: Bool = false,
                      operation: @escaping (VaultStore, ImportChoices) async throws -> UUID?) {
        guard let session = store else { return }
        guard !reviewingImport else { problem = "Un autre import est en cours."; return }
        reviewingImport = true
        extracting = extract
        activity()
        Task {
            defer {
                if store === session { reviewingImport = false; extracting = false }
            }
            var choices = ImportChoices()
            while store === session {
                do {
                    let open = try await operation(session, choices)
                    let updated = try await session.library()
                    guard store === session else { return }
                    library = updated
                    openAfterImport = open
                    if configuration.provider != .local { sync() }
                    return
                } catch let duplicate as DuplicateImport {
                    guard store === session else { return }
                    let choice = await withCheckedContinuation { continuation in
                        importAnswer = continuation
                        duplicateImport = duplicate
                    }
                    guard let choice else { return }
                    choices[duplicate.id] = choice
                } catch {
                    if store === session { problem = error.localizedDescription }
                    return
                }
            }
        }
    }
}

struct DuplicateImportPrompt: ViewModifier {
    let model: LockerModel

    func body(content: Content) -> some View {
        content.alert("Document déjà présent", isPresented: Binding(get: { model.duplicateImport != nil },
            set: { _ in }), presenting: model.duplicateImport) { _ in
            Button("Ouvrir l’exemplaire existant") { model.resolveDuplicate(.openExisting) }
            Button("Conserver les deux") { model.resolveDuplicate(.keepBoth) }
            Button("Annuler l’import", role: .cancel) { model.resolveDuplicate(nil) }
        } message: { duplicate in
            let location = duplicate.existing.folder.isEmpty ? "la racine du coffre" : "« " + duplicate.existing.folder + " »"
            Text("« " + duplicate.id.source + " » a le même contenu que « " + duplicate.existing.name + " » dans " + location + ".")
        }
    }
}
