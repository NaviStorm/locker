import Foundation

private final class DAVListing: NSObject, XMLParserDelegate {
    var contents = [String: String]()
    private var field = ""
    private var buffer = ""
    private var href = ""
    private var etag = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        field = elementName
        buffer = ""
        if field == "response" { href = ""; etag = "" }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { buffer += string }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let value = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if elementName == "href" { href = value }
        if elementName == "getetag" { etag = value }
        if elementName == "response", let name = URL(string: href)?.lastPathComponent {
            contents[name] = etag
        }
        buffer = ""
    }
}

struct WebDAVBucket: ObjectBucket {
    let root: URL
    private let auth: String

    init(server: String, user: String, password: String, vault: String) throws {
        guard let base = URL(string: server), base.scheme?.lowercased() == "https", base.host != nil,
              base.user == nil, base.password == nil, base.query == nil, base.fragment == nil,
              !user.contains(":") else { throw TransportError(message: "Indiquez un dossier WebDAV HTTPS valide.") }
        root = base.appendingPathComponent("locker-" + vault, isDirectory: true)
        auth = "Basic " + Data((user + ":" + password).utf8).base64EncodedString()
    }

    private func request(_ method: String, _ name: String? = nil) -> URLRequest {
        var request = URLRequest(url: name.map { root.appendingPathComponent($0) } ?? root)
        request.httpMethod = method
        request.setValue(auth, forHTTPHeaderField: "Authorization")
        return request
    }

    func inventory() async throws -> [String: String] {
        var query = request("PROPFIND")
        query.setValue("1", forHTTPHeaderField: "Depth")
        query.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        query.httpBody = Data(#"<d:propfind xmlns:d="DAV:"><d:prop><d:getetag/></d:prop></d:propfind>"#.utf8)
        var (data, response) = try await Network.send(query)
        if response.statusCode == 404 {
            let (_, create) = try await Network.send(request("MKCOL"))
            if create.statusCode != 405 { try Network.check(create) }
            (data, response) = try await Network.send(query)
        }
        try Network.check(response)
        let listing = DAVListing()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = listing
        guard response.statusCode == 207, parser.parse() else { throw VaultError.damaged }
        return listing.contents
    }

    func get(_ name: String) async throws -> BucketValue? {
        let (data, response) = try await Network.send(request("GET", name))
        if response.statusCode == 404 { return nil }
        try Network.check(response)
        guard let tag = response.value(forHTTPHeaderField: "ETag"), tag.hasPrefix("\""), tag.hasSuffix("\"") else {
            throw TransportError(message: "Ce serveur WebDAV doit fournir des ETag forts pour synchroniser en sécurité.")
        }
        return BucketValue(data: data, tag: tag)
    }

    func put(_ bytes: Data, name: String, replacing tag: String?) async throws {
        var upload = request("PUT", name)
        upload.setValue(tag ?? "*", forHTTPHeaderField: tag == nil ? "If-None-Match" : "If-Match")
        upload.httpBody = bytes
        let (_, response) = try await Network.send(upload)
        if response.statusCode == 412 { throw ReplicaError.conflict }
        try Network.check(response)
    }
}
