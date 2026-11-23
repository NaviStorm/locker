import Foundation
import XCTest
#if SWIFT_PACKAGE
@testable import LockerCore
#else
@testable import Locker
#endif

final class TransportTests: XCTestCase {
    private func reply(_ request: URLRequest, status: Int, text: String = "", headers: [String: String] = [:]) -> (Data, HTTPURLResponse) {
        (Data(text.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!)
    }

    func testWebDAVEnumerationAndConditionalWrite() async throws {
        var calls = 0
        let bucket = try WebDAVBucket(server: "https://nas.invalid/dav", user: "test", password: "fictif", vault: "abc") { req in
            calls += 1
            XCTAssertEqual(req.url?.host, "nas.invalid")
            XCTAssertNotNil(req.value(forHTTPHeaderField: "Authorization"))
            switch calls {
            case 1:
                XCTAssertEqual(req.httpMethod, "PROPFIND")
                return self.reply(req, status: 404)
            case 2:
                XCTAssertEqual(req.httpMethod, "MKCOL")
                return self.reply(req, status: 201)
            case 3:
                XCTAssertEqual(req.value(forHTTPHeaderField: "Depth"), "1")
                let xml = #"<d:multistatus xmlns:d="DAV:"><d:response><d:href>/dav/locker-abc/d-123</d:href><d:propstat><d:prop><d:getetag>"v1"</d:getetag></d:prop></d:propstat></d:response></d:multistatus>"#
                return self.reply(req, status: 207, text: xml)
            case 4:
                XCTAssertEqual(req.httpMethod, "GET")
                return self.reply(req, status: 200, text: "opaque", headers: ["ETag": "\"v1\""])
            default:
                XCTAssertEqual(req.httpMethod, "PUT")
                XCTAssertEqual(req.value(forHTTPHeaderField: "If-Match"), "\"v1\"")
                return self.reply(req, status: 412)
            }
        }
        let list = try await bucket.inventory()
        XCTAssertEqual(list["d-123"], "\"v1\"")
        let value = try await bucket.get("d-123")
        do { try await bucket.put(Data(), name: "d-123", replacing: value?.tag); XCTFail() } catch ReplicaError.conflict {}
        XCTAssertEqual(calls, 5)
    }

    func testDropboxPaginationTokenAndRevision() async throws {
        let bucket = DropboxBucket(client: "client-fictif", refresh: "refresh-fictif", folder: "/locker-test") { req in
            XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer session-fictive")
            switch req.url!.lastPathComponent {
            case "list_folder":
                return self.reply(req, status: 200, text: #"{"entries":[{"name":"d-a","rev":"1"}],"has_more":true,"cursor":"2"}"#)
            case "continue":
                return self.reply(req, status: 200, text: #"{"entries":[{"name":"d-b","rev":"3"}],"has_more":false}"#)
            case "upload":
                XCTAssertEqual(req.url?.host, "content.dropboxapi.com")
                let arg = try XCTUnwrap(req.value(forHTTPHeaderField: "Dropbox-API-Arg"))
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(arg.utf8)) as? [String: Any])
                XCTAssertEqual(json["mode"] as? [String: String], [".tag": "update", "update": "1"])
                return self.reply(req, status: 409, text: #"{"error_summary":"path/conflict/file/"}"#)
            default: throw VaultError.damaged
            }
        } renew: { fields in
            XCTAssertEqual(fields["refresh_token"], "refresh-fictif")
            return ["access_token": "session-fictive"]
        }
        let list = try await bucket.inventory()
        XCTAssertEqual(list, ["d-a": "1", "d-b": "3"])
        do { try await bucket.put(Data([4]), name: "d-a", replacing: "1"); XCTFail() } catch ReplicaError.conflict {}
    }
}
