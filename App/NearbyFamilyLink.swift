#if os(iOS)
import MultipeerConnectivity

@MainActor
final class NearbyFamilyLink: NSObject {
    private static let service = "locker-family"
    private let session: MCSession
    private var browser: MCNearbyServiceBrowser?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var peer: MCPeerID?
    private var active = false
    var onConnected: (() -> Void)?
    var onPacket: ((NearbyHandshake.Packet) -> Void)?
    var onFailure: ((String) -> Void)?

    override init() {
        let id = MCPeerID(displayName: "Locker-" + UUID().uuidString)
        session = MCSession(peer: id, securityIdentity: nil, encryptionPreference: .required)
        super.init()
        session.delegate = self
    }

    func start(as role: NearbyRole) {
        active = true
        if role == .owner {
            let item = MCNearbyServiceBrowser(peer: session.myPeerID, serviceType: Self.service)
            browser = item
            item.delegate = self
            item.startBrowsingForPeers()
        } else {
            let item = MCNearbyServiceAdvertiser(peer: session.myPeerID, discoveryInfo: nil, serviceType: Self.service)
            advertiser = item
            item.delegate = self
            item.startAdvertisingPeer()
        }
    }

    func send(_ packet: NearbyHandshake.Packet) throws {
        guard active, let peer else { throw VaultError.unavailable }
        try session.send(JSONEncoder().encode(packet), toPeers: [peer], with: .reliable)
    }

    func stop() {
        active = false
        browser?.stopBrowsingForPeers()
        advertiser?.stopAdvertisingPeer()
        session.disconnect()
        peer = nil
    }

    fileprivate func fail(_ reason: String) {
        guard active else { return }
        stop()
        onFailure?(reason)
    }
}

extension NearbyFamilyLink: MCNearbyServiceBrowserDelegate, MCNearbyServiceAdvertiserDelegate {
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer id: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        DispatchQueue.main.async {
            guard self.active, self.peer == nil else { return }
            self.peer = id
            browser.invitePeer(id, to: self.session, withContext: nil, timeout: 20)
        }
    }
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer id: MCPeerID) {}
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        DispatchQueue.main.async { self.fail("Recherche indisponible. Vérifiez l’autorisation Réseau local de Locker.") }
    }
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        DispatchQueue.main.async { self.fail("Détection indisponible. Vérifiez l’autorisation Réseau local de Locker.") }
    }
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer id: MCPeerID,
                                withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        DispatchQueue.main.async {
            guard self.active, self.peer == nil else { invitationHandler(false, nil); return }
            self.peer = id
            invitationHandler(true, self.session)
        }
    }
}

extension NearbyFamilyLink: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer id: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async {
            guard self.active, self.peer == id else { return }
            if state == .connected {
                self.browser?.stopBrowsingForPeers()
                self.advertiser?.stopAdvertisingPeer()
                self.onConnected?()
            } else if state == .notConnected { self.fail("Connexion interrompue. Rapprochez les deux iPhones et réessayez.") }
        }
    }
    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer id: MCPeerID) {
        DispatchQueue.main.async {
            guard self.active, self.peer == id else { return }
            guard data.count <= 2 * 1024 * 1024, let packet = try? JSONDecoder().decode(NearbyHandshake.Packet.self, from: data) else {
                self.fail("Message de jumelage illisible.")
                return
            }
            self.onPacket?(packet)
        }
    }
    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName name: String, fromPeer peerID: MCPeerID) { stream.close() }
    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName name: String, fromPeer peerID: MCPeerID,
                             with progress: Progress) { progress.cancel() }
    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName name: String, fromPeer peerID: MCPeerID,
                             at localURL: URL?, withError error: Error?) {}
}
#endif
