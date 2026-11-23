import CryptoKit
import Foundation

struct DropboxAuthorization {
    let client: String
    let verifier = Self.url64(SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
    let state = UUID().uuidString
    static let redirect = "locker-vault://oauth/dropbox"

    private static func url64(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    var startURL: URL {
        var url = URLComponents(string: "https://www.dropbox.com/oauth2/authorize")!
        url.queryItems = [
            URLQueryItem(name: "client_id", value: client), URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "state", value: state), URLQueryItem(name: "redirect_uri", value: Self.redirect),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: Self.url64(Data(SHA256.hash(data: Data(verifier.utf8))))),
            URLQueryItem(name: "token_access_type", value: "offline")
        ]
        return url.url!
    }

    func finish(callback: URL) async throws -> String {
        guard let parts = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              parts.scheme == "locker-vault", parts.host == "oauth", parts.path == "/dropbox",
              parts.queryItems?.first(where: { $0.name == "state" })?.value == state,
              let code = parts.queryItems?.first(where: { $0.name == "code" })?.value else {
            throw TransportError(message: "La réponse d’autorisation Dropbox est invalide.")
        }
        let token = try await Self.token(["client_id": client, "grant_type": "authorization_code", "code": code,
                                          "code_verifier": verifier, "redirect_uri": Self.redirect])
        guard let refresh = token["refresh_token"] as? String else { throw VaultError.unavailable }
        return refresh
    }

    static func token(_ fields: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://api.dropboxapi.com/oauth2/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = Data((form.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        let (data, response) = try await Network.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw VaultError.unavailable }
        try Network.check(http)
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw VaultError.damaged }
        return result
    }
}

actor DropboxBucket: ObjectBucket {
    private let client: String
    private let refresh: String
    let folder: String
    private var bearer: String?

    init(client: String, refresh: String, folder: String) {
        self.client = client
        self.refresh = refresh
        self.folder = folder
    }

    func send(_ endpoint: String, _ arguments: [String: Any], upload: Data? = nil,
                      content: Bool = false, sharing: Bool = false) async throws -> (Data, HTTPURLResponse) {
        for _ in 0..<2 {
            if bearer == nil {
                let response = try await DropboxAuthorization.token(["client_id": client, "refresh_token": refresh,
                                                                    "grant_type": "refresh_token"])
                guard let token = response["access_token"] as? String else { throw VaultError.unavailable }
                bearer = token
            }
            let host = content ? "content.dropboxapi.com" : "api.dropboxapi.com"
            var request = URLRequest(url: URL(string: "https://" + host + (sharing ? "/2/sharing/" : "/2/files/") + endpoint)!)
            request.httpMethod = "POST"
            request.setValue("Bearer " + (bearer ?? ""), forHTTPHeaderField: "Authorization")
            let json = try JSONSerialization.data(withJSONObject: arguments)
            if content {
                // Folder names are opaque ASCII; arguments are valid HTTP field values.
                request.setValue(String(decoding: json, as: UTF8.self), forHTTPHeaderField: "Dropbox-API-Arg")
                if let upload {
                    request.httpBody = upload
                    request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                }
            } else {
                request.httpBody = json
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            let result = try await Network.send(request)
            if result.1.statusCode != 401 { return result }
            bearer = nil
        }
        throw TransportError(message: "Reconnectez le compte Dropbox.")
    }

    private func summary(_ data: Data) -> String {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["error_summary"] as? String ?? ""
    }

    func inventory() async throws -> [String: String] {
        var result = [String: String]()
        var page = try await send("list_folder", ["path": folder])
        if page.1.statusCode == 409, summary(page.0).hasPrefix("path/not_found") {
            let created = try await send("create_folder_v2", ["path": folder, "autorename": false])
            if !summary(created.0).hasPrefix("path/conflict/folder") { try Network.check(created.1) }
            page = try await send("list_folder", ["path": folder])
        }
        while true {
            try Network.check(page.1)
            guard let object = try JSONSerialization.jsonObject(with: page.0) as? [String: Any],
                  let rows = object["entries"] as? [[String: Any]], let more = object["has_more"] as? Bool else {
                throw VaultError.damaged
            }
            for row in rows {
                if let name = row["name"] as? String, let rev = row["rev"] as? String { result[name] = rev }
            }
            if !more { return result }
            guard let cursor = object["cursor"] as? String else { throw VaultError.damaged }
            page = try await send("list_folder/continue", ["cursor": cursor])
        }
    }

    func get(_ name: String) async throws -> BucketValue? {
        let (data, response) = try await send("download", ["path": folder + "/" + name], content: true)
        if response.statusCode == 409, summary(data).hasPrefix("path/not_found") { return nil }
        try Network.check(response)
        guard let header = response.value(forHTTPHeaderField: "Dropbox-API-Result"),
              let meta = try JSONSerialization.jsonObject(with: Data(header.utf8)) as? [String: Any],
              let tag = meta["rev"] as? String else { throw VaultError.damaged }
        return BucketValue(data: data, tag: tag)
    }

    func put(_ bytes: Data, name: String, replacing tag: String?) async throws {
        let mode: Any = tag.map { [".tag": "update", "update": $0] as Any } ?? "add"
        let (data, response) = try await send("upload", ["path": folder + "/" + name, "mode": mode,
            "autorename": false, "strict_conflict": true, "mute": true], upload: bytes, content: true)
        if response.statusCode == 409, summary(data).contains("conflict") { throw ReplicaError.conflict }
        try Network.check(response)
    }
}
