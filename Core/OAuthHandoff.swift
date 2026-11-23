import Foundation
import Security

/// Only a public recipient and a local slot identifier accompany the external browser session.
struct OAuthHandoff {
    let slot: String
    let recipient: PublicIdentity
    struct Credentials: Codable {
        let config: ProviderSettings
        let refresh: String
    }
    func finish(config: ProviderSettings, refresh: String) throws {
        let plain = try JSONEncoder().encode(Credentials(config: config, refresh: refresh))
        let sealed = try SealedGrant(plain, for: recipient)
        try ProviderCredential(account: "oauth-stage-" + slot).save(JSONEncoder().encode(sealed))
    }
}

extension VaultStore {
    func resumeDropboxAuthorization() throws {
        try gate.check()
        let item = ProviderCredential(account: "oauth-stage-" + root.lastPathComponent)
        let data: Data
        do { data = try item.read() }
        catch let error as KeychainFailure where error.status == errSecItemNotFound { return }
        let grant = try JSONDecoder().decode(SealedGrant.self, from: data)
        let plain = try identity().decrypt(grant)
        let credentials = try JSONDecoder().decode(OAuthHandoff.Credentials.self, from: plain)
        guard credentials.config.provider == .dropbox else { throw VaultError.damaged }
        try configure(credentials.config, credential: credentials.refresh)
        let status = SecItemDelete(item.query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainFailure(status: status) }
    }
}
